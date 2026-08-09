// StudioBatchMatchModel.swift
// Runs the studio match over a whole library.
//
// Built the same way as `ActorBatchMatchModel`, which was built the same way as
// the video one, for the reason stated there: a library where "match
// everything" means one thing for people and another for companies is a library
// nobody can reason about.
//
// What is different is the payoff. An actor match fills in one record. A studio
// match asserts a SECOND node and an edge — confirming an imprint also asserts
// the network that owns it — so this is the run that builds the hierarchy the
// `studio_parent` table has been empty of.
//
// Resumable by construction: every profile is written as it completes and the
// skip rule means a re-run costs only what is left.

import Foundation
import Combine
import LibraryCore

@MainActor
final class StudioBatchMatchModel: ObservableObject {

    struct QueuedStudio: Identifiable {
        let profile: EntityProfile
        let candidates: [PluginCandidate]
        /// The library this profile lives in, carried from the crawl rather
        /// than re-derived at review time — the video side learned that
        /// falling back to "the first library" writes into a database with no
        /// such row, throws, and silently returns the record to the queue.
        let libraryURL: URL
        var id: String { profile.id }
        var name: String {
            profile.name
        }
    }

    /// A studio whose network the source and the library disagree about.
    ///
    /// ⚠️ Kept rather than counted, and nothing was changed for them. Which
    /// company owns an imprint is a fact about the world the operator may know
    /// better than the source, so these are handed back.
    struct ParentConflict: Identifiable {
        let studio: String
        let existing: String
        let offered: String
        var id: String { studio }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var report = StudioBatchReport()
    @Published private(set) var queue: [QueuedStudio] = []
    @Published private(set) var noMatches: [QueuedStudio] = []
    @Published private(set) var failures: [QueuedStudio] = []
    @Published private(set) var conflicts: [ParentConflict] = []
    /// Networks this run created that the library had never heard of.
    @Published private(set) var networksDiscovered: [String] = []
    @Published private(set) var total = 0
    @Published private(set) var current = ""
    @Published private(set) var finished = false

    private let libraryURLs: [URL]
    private var cancelled = false

    init(libraryURLs: [URL]) { self.libraryURLs = libraryURLs }

    var libraryNames: [String] { libraryURLs.map { $0.lastPathComponent } }

    private var provider: (any StudioMetadataProvider)? {
        PluginEnvironment.registry.installedStudioProviders().first
    }

    var providerName: String { provider?.displayName ?? "no provider" }
    var hasProvider: Bool { provider != nil }

    func cancel() { cancelled = true }

    func run() async {
        guard let provider else { return }
        isRunning = true
        finished = false
        cancelled = false
        report = StudioBatchReport()
        queue = []; noMatches = []; failures = []; conflicts = []; networksDiscovered = []
        settledByYou = 0

        // Counted in full before starting. The video side had a bug where the
        // total accumulated inside the loop, so a two-library run showed the
        // first library's count and the bar could never pass halfway.
        total = libraryURLs.reduce(0) { running, url in
            running + ((try? LibraryStore(at: url).fetchAllEntityProfiles()
                .filter { $0.id.hasPrefix("studio:") }.count) ?? 0)
        }

        let delay = UInt64((1.0 / max(provider.requestsPerSecond, 0.1)) * 1_000_000_000)

        for libraryURL in libraryURLs {
            guard let store = try? LibraryStore(at: libraryURL),
                  let profiles = try? store.fetchAllEntityProfiles()
                    .filter({ $0.id.hasPrefix("studio:") }) else { continue }

            for profile in profiles {
                if cancelled { break }
                current = displayName(profile)

                if let reason = StudioBatchPolicy.skipReason(for: profile) {
                    report.record(.skipped(reason: reason))
                    continue
                }

                let outcome = await examine(profile, in: libraryURL,
                                            provider: provider, store: store)
                report.record(outcome)

                switch outcome {
                case .noMatch:
                    noMatches.append(QueuedStudio(profile: profile, candidates: [],
                                                  libraryURL: libraryURL))
                case .failed:
                    failures.append(QueuedStudio(profile: profile, candidates: [],
                                                 libraryURL: libraryURL))
                default: break
                }

                // Written as it goes. A run that only persists at the end loses
                // everything to one interruption.
                if let state = outcome.recordedState {
                    var updated = appliedProfile ?? profile
                    updated.enrichmentState = state
                    updated.enrichmentSource = provider.displayName
                    updated.enrichmentCheckedAt = Date()
                    if case .applied = outcome {} else {
                        // A non-match clears any id left from a previous run,
                        // so provenance never points at a record we are no
                        // longer matched to.
                        updated.enrichmentSourceId = nil
                    }
                    try? store.saveEntityProfile(updated)

                    // The match edge as well as the columns (v31).
                    if case .applied = outcome, let sourceId = updated.enrichmentSourceId {
                        try? store.recordMatch(
                            NodeMatch(nodeId: updated.id, source: providerName,
                                      sourceId: sourceId, method: .name),
                            isVideo: false)
                    } else if case .applied = outcome {} else {
                        try? store.removeMatch(nodeId: updated.id,
                                               source: providerName, isVideo: false)
                    }
                    // The parent is written only once the studio itself has
                    // been saved — an edge to a row that does not exist yet is
                    // an edge pointing at nothing.
                    if case let .applied(_, parent) = outcome,
                       case let .recorded(name, parentSourceId) = parent {
                        recordParent(name, sourceId: parentSourceId,
                                     for: updated.id, in: store)
                    }
                }
                appliedProfile = nil
                try? await Task.sleep(nanoseconds: delay)
            }
            if cancelled { break }
        }

        current = ""
        isRunning = false
        finished = true
        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
    }

    /// Carries the merged profile out of `examine` without widening the
    /// outcome type, which only the report needs to understand.
    private var appliedProfile: EntityProfile?

    private func examine(_ profile: EntityProfile, in libraryURL: URL,
                         provider: any StudioMetadataProvider,
                         store: LibraryStore) async -> StudioBatchOutcome {
        let name = displayName(profile)
        guard !name.isEmpty else { return .skipped(reason: "no name") }

        let candidates: [PluginCandidate]
        do {
            candidates = try await provider.search(name: name)
        } catch {
            return .failed(friendly(error))
        }
        guard !candidates.isEmpty else { return .noMatch }

        // ⚠️ More than one is a QUESTION, not a match. Two networks can use the
        // same imprint name — which is exactly why a studio carries a source id
        // at all — and a run picking the first records a match nothing brings
        // back for review.
        guard StudioBatchPolicy.isDecisive(candidateCount: candidates.count),
              let hit = candidates.first else {
            queue.append(QueuedStudio(profile: profile, candidates: candidates,
                                      libraryURL: libraryURL))
            return .queued(candidateCount: candidates.count)
        }

        let proposal: StudioMetadataProposal
        do {
            proposal = try await provider.fetch(studioId: hit.id)
        } catch {
            return .failed(friendly(error))
        }

        let existingParent = (try? store.studioParentPairs())?
            .first { $0.from == profile.id }
            .map { String($0.to.dropFirst(7)) }

        let disposition = StudioBatchPolicy.parentDisposition(existing: existingParent,
                                                              proposal: proposal)
        if case let .conflict(existing, offered) = disposition {
            conflicts.append(ParentConflict(studio: name, existing: existing, offered: offered))
        }

        let fields = StudioBatchPolicy.autoApplicableFields(current: profile, proposal: proposal)
        var merged = profile
        if fields.contains(StudioBatchPolicy.Field.bio) { merged.bio = proposal.bio.value }
        if fields.contains(StudioBatchPolicy.Field.homePage) {
            merged.homePage = proposal.homePage.value
        }
        if fields.contains(StudioBatchPolicy.Field.akas) {
            merged.akas = proposal.akas.value ?? []
        }
        if fields.contains(StudioBatchPolicy.Field.links) {
            merged.links = proposal.externalLinks.value ?? []
        }
        // The chosen record's id IS the match. Keeping it turns every later
        // lookup from a re-search by name into a fetch.
        merged.enrichmentSourceId = proposal.sourceId.value ?? hit.id
        appliedProfile = merged

        var written = Array(fields)
        if case .recorded = disposition { written.append(StudioBatchPolicy.Field.parent) }
        return .applied(fields: written, parent: disposition)
    }

    /// Takes a studio off the queue once the operator has decided about it.
    ///
    /// ⚠️ The report is deliberately NOT adjusted. `report` is the record of
    /// what the unattended run did, and folding a hand-made decision into
    /// `applied` would claim the run matched something it explicitly refused
    /// to. What the operator settled is counted separately and shown as such.
    func settle(_ queued: QueuedStudio) {
        queue.removeAll { $0.id == queued.id }
        settledByYou += 1
    }

    /// Records the operator resolved after the run, so the queue shrinking is
    /// explained rather than looking like rows going missing.
    @Published private(set) var settledByYou = 0

    /// The network already recorded for a queued studio, if any.
    ///
    /// Read at review time rather than carried from the crawl: the operator may
    /// have settled another studio in between, and a stale answer here would
    /// present an agreement as a conflict.
    func recordedParent(for queued: QueuedStudio) -> String? {
        guard let store = try? LibraryStore(at: queued.libraryURL),
              // `try?` on a method returning `String?` gives `String??` —
              // flattened here rather than double-unwrapped in a condition.
              let parentId = (try? store.parentStudioId(of: queued.profile.id)) ?? nil
        else { return nil }
        return parentId.hasPrefix("studio:") ? String(parentId.dropFirst(7)) : parentId
    }

    /// Creates the network as a studio in its own right, then records the edge.
    ///
    /// ⚠️ `confirmStudio` is idempotent and non-destructive — a network already
    /// known keeps everything it had. It is called before the edge because an
    /// edge to a studio with no profile is a dangling parent, which is one of
    /// the defects Studio Health reports.
    private func recordParent(_ name: String, sourceId: String?,
                              for studioId: String, in store: LibraryStore) {
        let isNew = ((try? store.fetchEntityProfile(named: name, type: "studio")) ?? nil) == nil
        try? store.confirmStudio(name, source: providerName, sourceId: sourceId)
        // ⚠️ Resolved AFTER the confirm, which is what creates the row when it
        // is new — asking before would find nothing and skip the hierarchy.
        if let parentId = try? store.entityId(named: name, type: "studio") {
            try? store.setStudioParent(parentId, forStudio: studioId)
        }
        if isNew, !networksDiscovered.contains(name) { networksDiscovered.append(name) }
    }

    private func displayName(_ profile: EntityProfile) -> String {
        profile.name
    }

    private func friendly(_ error: Error) -> String {
        (error as? PluginError)?.localizedDescription ?? error.localizedDescription
    }
}
