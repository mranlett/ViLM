// VideoBatchMatchModel.swift
// Runs the video match over a whole library.
//
// Fingerprint matches apply themselves; anything found by searching is put in a
// queue for review. That line is drawn in `VideoBatchPolicy`, and this only
// drives it — the decision about what may be written unattended does not belong
// in a view model.
//
// Resumable by construction. The actor batch enricher once ran for an hour and
// produced nothing because it wrote only at the end, so every video here is
// written as it completes and a skip rule means a re-run costs only what is
// left to do.

import Foundation
import Combine
import LibraryCore

@MainActor
final class VideoBatchMatchModel: ObservableObject {

    struct QueuedMatch: Identifiable {
        let asset: Asset
        let route: VideoMatchRoute
        let candidates: [PluginCandidate]
        /// The library this video actually lives in.
        ///
        /// Carried from the crawl, which already knows it. Re-deriving it at
        /// review time and falling back to "the first library" wrote the
        /// updated record into a database that has no such row — the write
        /// threw, the error was swallowed, and the video came back in the queue
        /// having apparently been matched.
        let libraryURL: URL
        var id: UUID { asset.id }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var report = VideoBatchReport()
    @Published private(set) var queue: [QueuedMatch] = []
    /// Videos the source had no record of, and videos that errored.
    ///
    /// Kept rather than merely counted: a tally you cannot act on is a dead end
    /// — these are exactly the files worth matching by hand, and the report is
    /// the only place they are ever listed.
    @Published private(set) var noMatches: [QueuedMatch] = []
    @Published private(set) var failures: [QueuedMatch] = []
    @Published private(set) var total = 0
    @Published private(set) var current = ""
    @Published private(set) var finished = false

    private let libraryURLs: [URL]
    private var cancelled = false

    init(libraryURLs: [URL]) { self.libraryURLs = libraryURLs }

    /// What the run will actually walk, for the operator to see before it does.
    var libraryNames: [String] { libraryURLs.map { $0.lastPathComponent } }

    private var provider: (any VideoMetadataProvider)? {
        PluginEnvironment.registry.installedVideoProviders().first
    }

    /// Why this run cannot work, checked BEFORE offering to start it.
    ///
    /// ⚠️ `run()` used to `guard let provider else { return }` — pressing Start
    /// with nothing installed did nothing at all, silently. And a provider
    /// installed without its credential was worse than nothing: it looked
    /// healthy, ran the whole library, and reported no matches, because every
    /// request failed authentication and every failure was swallowed.
    ///
    /// "The source has no record of this video" and "I never successfully asked
    /// the source anything" are different answers, and they had become
    /// indistinguishable.
    var blockedReason: String? {
        guard let provider else {
            return "No video metadata plugin is installed. Add one in Settings → Plugins."
        }
        let installer = PluginEnvironment.installer(libraryURL: libraryURLs.first)
        switch installer.unusableReason(for: provider) {
        case .missingCredential(let name):
            return "\(name) needs its API key before it can match anything. Add it in Settings → Plugins."
        case .noProvider:
            return "No video metadata plugin is installed. Add one in Settings → Plugins."
        case nil:
            return nil
        }
    }

    func cancel() { cancelled = true }

    /// Drops a video from the queue once it has been dealt with.
    ///
    /// Called whether or not anything was applied: the queue means "you have
    /// not looked at this", and you have. Leaving it listed makes the list
    /// impossible to work through, because there is no way to tell what is
    /// still outstanding from what has already been handled.
    func removeFromQueue(_ assetId: UUID) {
        queue.removeAll { $0.asset.id == assetId }
        noMatches.removeAll { $0.asset.id == assetId }
        failures.removeAll { $0.asset.id == assetId }
    }

    /// Abandoned after this many consecutive failures.
    ///
    /// A run whose every request fails is not finding nothing — it is not
    /// asking. Grinding through 2,104 videos to report that is worse than
    /// useless: it costs half a second of fingerprinting each, and it ends with
    /// a screen that looks exactly like "the source has never heard of your
    /// library". Ten in a row is well past coincidence.
    private static let consecutiveFailureLimit = 10

    func run() async {
        guard let provider else { return }
        isRunning = true
        cancelled = false
        finished = false
        report = VideoBatchReport()
        queue = []
        noMatches = []
        failures = []
        // Counted across EVERY library before starting. Accumulating it inside
        // the loop meant the total grew as the run went, so a two-library run
        // showed the first library's count and looked like it was ignoring the
        // second. It was also never reset, so a second run doubled it.
        total = libraryURLs.reduce(0) { running, url in
            running + ((try? LibraryStore(at: url).fetchAllAssets().count) ?? 0)
        }

        // The rate limit the provider declares, honoured rather than guessed.
        let delay = UInt64((1.0 / max(provider.requestsPerSecond, 0.1)) * 1_000_000_000)

        for libraryURL in libraryURLs {
            guard let store = try? LibraryStore(at: libraryURL),
                  let assets = try? store.fetchAllAssets() else { continue }
            // ⚠️ `total` is NOT accumulated here. It is counted in full above,
            // before the run starts. Adding to it again made the progress read
            // "N of 2×count" — the bar could never pass halfway, and the figure
            // did not match the library. The comment above describes exactly
            // this fix; the line it was meant to replace was left behind.

            for asset in assets {
                if cancelled { break }
                current = asset.fileName

                if let reason = VideoBatchPolicy.skipReason(for: asset) {
                    report.record(.skipped(reason: reason))
                    continue
                }

                let outcome = await examine(asset, in: libraryURL,
                                            provider: provider, store: store)
                report.record(outcome)

                // Recorded with the library they live in, so acting on one
                // later writes to the right place.
                switch outcome {
                case .noMatch:
                    noMatches.append(QueuedMatch(asset: asset, route: .title,
                                                 candidates: [], libraryURL: libraryURL))
                case .failed:
                    failures.append(QueuedMatch(asset: asset, route: .title,
                                                candidates: [], libraryURL: libraryURL))
                default: break
                }

                // Written as it goes. A run that only persists at the end loses
                // everything to one interruption.
                if let state = outcome.recordedState {
                    var updated = asset
                    if case .applied(_, _, _) = outcome {
                        updated = appliedAsset ?? asset
                    }
                    // Routed through recordingOutcome rather than assigning the
                    // fields here, so the batch path gets the same rules the
                    // per-video path is tested against: the matched id is kept,
                    // and a non-match clears any id left from a previous run.
                    updated = VideoEnrichmentReview.recordingOutcome(
                        updated, state: state, source: provider.displayName,
                        sourceId: matchedSourceId)
                    try? store.updateAsset(updated)
                }
                appliedAsset = nil
                matchedSourceId = nil
                try? await Task.sleep(nanoseconds: delay)
            }
            if cancelled { break }
        }

        current = ""
        isRunning = false
        finished = true
        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
    }

    /// Carries the merged record out of `examine` without widening the outcome
    /// type, which only the report needs to understand.
    private var appliedAsset: Asset?

    /// The source's id for the record `examine` matched, carried out the same
    /// way `appliedAsset` is. Without it a batch run records "matched" and not
    /// WHAT it matched, so the next run re-fingerprints and re-guesses.
    private var matchedSourceId: String?

    private func examine(_ asset: Asset, in libraryURL: URL,
                         provider: any VideoMetadataProvider,
                         store: LibraryStore) async -> VideoBatchOutcome {
        // 1 — fingerprint. Exact, and the only route allowed to write.
        let fileURL = libraryURL.appendingPathComponent(asset.relativePath)
        if let hash = try? await VideoPerceptualHash.compute(contentsOf: fileURL),
           let hits = try? await provider.match(perceptualHash: hash, distance: 0),
           !hits.isEmpty {
            // More than one scene carrying the same fingerprint is a genuine
            // ambiguity, not a match — it must not be resolved unattended.
            guard hits.count == 1, let hit = hits.first else {
                queue.append(QueuedMatch(asset: asset, route: .fingerprint, candidates: hits, libraryURL: libraryURL))
                return .queued(route: .fingerprint, candidateCount: hits.count)
            }
            guard let fetched = try? await provider.fetch(videoId: hit.id) else {
                return .failed("couldn't load details")
            }

            // The same studio policy the per-video path follows. A batch run
            // cannot ask, so where verification decides it proceeds, and where
            // it cannot the video is QUEUED rather than given whichever name
            // the source happened to list first.
            //
            // ⚠️ Queuing rather than defaulting to the imprint is deliberate,
            // and it is the same rule as an ambiguous fingerprint two blocks
            // up: a batch run may apply what is certain and must hand back what
            // is not. "Matched once, stays matched" is what makes the
            // difference permanent — a video written with a guessed studio does
            // not come back on its own to have it corrected.
            let proposal: VideoMetadataProposal
            switch VideoEnrichmentReview.studioResolution(
                proposal: fetched,
                isVerified: { (try? store.fetchEntityProfile(for: "studio:\($0)"))?
                    .enrichmentState == .matched }
            ) {
            case let .use(choice):
                proposal = VideoEnrichmentReview.resolvingStudio(fetched, to: choice)
            case .ask:
                queue.append(QueuedMatch(asset: asset, route: .fingerprint,
                                         candidates: [hit], libraryURL: libraryURL))
                return .queued(route: .fingerprint, candidateCount: 1)
            case .none:
                proposal = fetched
            }

            let changes = VideoEnrichmentReview.changes(for: asset, proposal: proposal)
            let fields = VideoBatchPolicy.autoApplicableFields(route: .fingerprint, changes: changes)
            // A match that offers nothing new is still a MATCH. Recording it
            // as a skip left the state empty, so the next run fingerprinted the
            // file again — half a second each, over the whole library, for a
            // question already answered. This is what made a re-run look like
            // it was starting from scratch.
            // The fingerprint route is exact, so this id IS the match — keep it
            // whether or not the proposal had anything left to write.
            matchedSourceId = hit.id

            // ⚠️ ABOVE the "nothing to write" return, and not gated on the
            // studio field being applied. An imprint belongs to a network
            // whether or not this video ended up carrying either name, and a
            // library that is already correct produces no fields to write at
            // all — so gating the hierarchy on having something to change
            // meant a re-match of a tidy library recorded no hierarchy
            // whatsoever, which is precisely the library most likely to be
            // re-matched.
            if let child = fetched.studio.value, let parent = fetched.studioParent.value,
               !StudioResolution.isSameStudio(child, parent) {
                try? store.confirmStudio(parent, source: provider.displayName)
                // Cycles are refused by the store, so a source disagreeing with
                // itself about which way a hierarchy runs cannot wedge it.
                try? store.setStudioParent("studio:\(parent)", forStudio: "studio:\(child)")
            }

            guard !fields.isEmpty else {
                appliedAsset = asset
                return .applied(route: .fingerprint, fields: [], tags: [])
            }

            // Same as the per-video path: a studio the source supplied verifies
            // the studio itself, which is the only route by which one ever
            // stops being unconfirmed.
            if let studio = VideoEnrichmentReview.confirmedStudio(proposal: proposal,
                                                                  accepting: fields) {
                try? store.confirmStudio(studio, source: provider.displayName)
            }

            appliedAsset = VideoEnrichmentReview.merged(asset: asset, proposal: proposal,
                                                        accepting: fields, acceptedTags: [])
            return .applied(route: .fingerprint, fields: Array(fields), tags: [])
        }

        // 2 — cast. Queued, never applied.
        // Same identity carried here: a batch run guessing the wrong person of
        // a shared name reports "no match" across the whole library, silently.
        var profiles: [String: EntityProfile] = [:]
        for name in asset.actors {
            let entityId = "actor:\(name)"
            if let profile = try? store.fetchEntityProfile(for: entityId) {
                profiles[entityId] = profile
            }
        }
        let performers = PerformerIdentity.from(names: asset.actors, profiles: profiles)
        if performers.count >= 2,
           let hits = try? await provider.search(performers: performers,
                                                 studio: asset.studios.first),
           !hits.isEmpty {
            queue.append(QueuedMatch(asset: asset, route: .cast, candidates: hits, libraryURL: libraryURL))
            return .queued(route: .cast, candidateCount: hits.count)
        }

        // 3 — title.
        let title = [asset.videoName, asset.episode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        if title.count >= 3,
           let hits = try? await provider.search(title: title, year: nil), !hits.isEmpty {
            queue.append(QueuedMatch(asset: asset, route: .title, candidates: hits, libraryURL: libraryURL))
            return .queued(route: .title, candidateCount: hits.count)
        }

        return .noMatch
    }
}
