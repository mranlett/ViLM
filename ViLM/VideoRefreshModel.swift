// VideoRefreshModel.swift
// Re-reads videos the library has ALREADY matched, to pick up data it could not
// store when the match was made.
//
// 🚨 The situation this answers. A batch run reports a matched video as
// "skipped" and never fetches it — correctly, since re-identifying a settled
// video costs a full disk read to reach the same answer. But the app has since
// learned to store the name a performer was credited under, the network above
// an imprint, and a studio's own identifier. A video matched before those
// existed keeps its match and would never gain them.
//
// ⭐ Cheap, because the video's own id was recorded at match time. This is a
// direct lookup: no fingerprint, no disk read, no search, and no ambiguity to
// re-settle — which is the expensive part of matching and the part needing a
// person.
//
// ⚠️ A REFRESH, not a re-match. It never changes which record a video is
// matched to.

import Foundation
import Combine
import LibraryCore

@MainActor
final class VideoRefreshModel: ObservableObject {

    struct QueuedConflict: Identifiable {
        var id: UUID { asset.id }
        let asset: Asset
        let libraryURL: URL
        let fields: [VideoFieldChange]
    }

    struct Report {
        var refreshed = 0
        var alreadyComplete = 0
        var queued = 0
        var failed = 0
        /// Matched before the app recorded which record — unreachable here.
        var noSourceId = 0
        var notMatched = 0
        var credits = 0
        var hierarchies = 0

        var examined: Int { refreshed + alreadyComplete + queued + failed }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var finished = false
    @Published private(set) var progress = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var report = Report()
    @Published private(set) var queue: [QueuedConflict] = []
    @Published private(set) var blockedReason: String?

    private let libraryURLs: [URL]
    private var cancelled = false

    init(libraryURLs: [URL]) {
        self.libraryURLs = libraryURLs
        if PluginEnvironment.registry.installedVideoProviders().first == nil {
            blockedReason = "No video metadata source is installed."
        }
    }

    private var provider: (any VideoMetadataProvider)? {
        PluginEnvironment.registry.installedVideoProviders().first
    }

    func cancel() { cancelled = true }

    func removeFromQueue(_ id: UUID) {
        queue.removeAll { $0.asset.id == id }
    }

    func run() async {
        guard let provider else { return }
        isRunning = true
        finished = false
        cancelled = false
        report = Report()
        queue = []

        // Counted first so the progress figure means something. A run that
        // discovers its own size while going is one that cannot say how far in
        // it is, which on a library this size is most of the experience.
        var work: [(asset: Asset, url: URL, sourceId: String)] = []
        for url in libraryURLs {
            guard let store = try? LibraryStore(at: url),
                  let assets = try? store.fetchAllAssets() else { continue }
            for asset in assets {
                switch VideoRefreshPolicy.eligibility(for: asset) {
                case .refresh(let sourceId): work.append((asset, url, sourceId))
                case .noSourceId:            report.noSourceId += 1
                case .notMatched:            report.notMatched += 1
                case .ruledOut, .ambiguous:  break
                }
            }
        }
        total = work.count

        let delay = UInt64(0.35 * 1_000_000_000)
        for item in work {
            if cancelled { break }
            progress = item.asset.fileName
            await refresh(item.asset, in: item.url, sourceId: item.sourceId,
                          provider: provider)
            done += 1
            try? await Task.sleep(nanoseconds: delay)
        }

        progress = ""
        isRunning = false
        finished = true
    }

    private func refresh(_ asset: Asset, in libraryURL: URL, sourceId: String,
                         provider: any VideoMetadataProvider) async {
        let proposal: VideoMetadataProposal
        do {
            proposal = try await provider.fetch(videoId: sourceId)
        } catch {
            // ⚠️ Not a verdict about the video. Nothing is recorded, so a
            // re-run retries it rather than treating a dropped connection as
            // "this video has nothing more to give".
            report.failed += 1
            return
        }

        guard let store = try? LibraryStore(at: libraryURL) else {
            report.failed += 1
            return
        }

        // ⚠️ knownTags empty and tags never applied — see `refreshesTags`.
        let changes = VideoEnrichmentReview.changes(for: asset, proposal: proposal)
        let fills = VideoRefreshPolicy.autoApplicable(changes)
        let conflicts = VideoRefreshPolicy.conflicts(changes)

        if !fills.isEmpty {
            let updated = VideoEnrichmentReview.merged(asset: asset, proposal: proposal,
                                                       accepting: fills, acceptedTags: [])
            try? store.updateAsset(updated)
        }

        // ⭐ The reason this pass exists. Credits are per-appearance and no
        // other tool can recover them — a studio hierarchy can at least come
        // from Match All Studios.
        let credits = VideoEnrichmentReview.credits(
            from: proposal, accepting: [VideoEnrichmentReview.Field.performers])
        if !credits.isEmpty,
           let written = try? store.recordCredits(credits, forVideo: asset.id), written > 0 {
            report.credits += written
        }

        // The imprint, its id, and the network above it. Confirming a studio is
        // additive, and an already-confirmed one with no id can now learn one.
        if let studio = proposal.studio.value, !studio.isEmpty {
            try? store.confirmStudio(studio, source: provider.displayName,
                                     sourceId: proposal.studioSourceId.value)
        }
        if let child = proposal.studio.value, let parent = proposal.studioParent.value,
           !StudioResolution.isSameStudio(child, parent) {
            try? store.confirmStudio(parent, source: provider.displayName,
                                     sourceId: proposal.studioParentSourceId.value)
            // Cycles are refused by the store, and an existing parent is never
            // overruled — `setStudioParent` re-asserting the same one is a
            // no-op rather than a new period.
            if (try? store.parentStudioId(of: "studio:\(child)")) == nil {
                try? store.setStudioParent("studio:\(parent)", forStudio: "studio:\(child)")
                report.hierarchies += 1
            }
        }

        if !conflicts.isEmpty {
            queue.append(QueuedConflict(asset: asset, libraryURL: libraryURL,
                                        fields: conflicts))
        }

        switch VideoRefreshPolicy.outcome(filled: Array(fills),
                                          conflicted: conflicts.map(\.field)) {
        case .filled:          report.refreshed += 1
        case .alreadyComplete: report.alreadyComplete += 1
        case .queued:          report.queued += 1
        case .filledAndQueued:
            report.refreshed += 1
            report.queued += 1
        case .skipped, .failed: break
        }
    }
}
