// ActorBatchMatchModel.swift
// Runs the actor match over a whole library.
//
// The actor equivalent of `VideoBatchMatchModel`, and deliberately built the
// same way. Batch actor enrichment used to live outside the app as a CSV tool
// with its own rules about overwriting, so "match everything" meant one thing
// for videos and something else for people. Now both drive a policy object and
// neither view model decides what may be written unattended.
//
// Resumable by construction. Every profile is written as it completes and the
// skip rule means a re-run costs only what is left — the CSV tool wrote only at
// the end, and an hour-long run that was interrupted produced nothing at all.

import Foundation
import Combine
import LibraryCore

@MainActor
final class ActorBatchMatchModel: ObservableObject {

    struct QueuedActor: Identifiable {
        let profile: EntityProfile
        let candidates: [PluginCandidate]
        /// The library this profile actually lives in. Carried from the crawl
        /// rather than re-derived at review time — the video side learned that
        /// falling back to "the first library" writes into a database with no
        /// such row, throws, and silently returns the record to the queue.
        let libraryURL: URL
        var id: String { profile.id }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var report = ActorBatchReport()
    @Published private(set) var queue: [QueuedActor] = []
    /// People the source had no record of, and people whose lookup errored.
    /// Kept rather than counted: these are exactly who is worth doing by hand.
    @Published private(set) var noMatches: [QueuedActor] = []
    @Published private(set) var failures: [QueuedActor] = []
    @Published private(set) var total = 0
    @Published private(set) var current = ""
    @Published private(set) var finished = false

    private let libraryURLs: [URL]
    private var cancelled = false

    init(libraryURLs: [URL]) { self.libraryURLs = libraryURLs }

    var libraryNames: [String] { libraryURLs.map { $0.lastPathComponent } }

    private var provider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installedActorProviders().first
    }

    var providerName: String { provider?.displayName ?? "no provider" }
    var hasProvider: Bool { provider != nil }

    func cancel() { cancelled = true }

    func run() async {
        guard let provider else { return }
        isRunning = true
        finished = false
        cancelled = false
        report = ActorBatchReport()
        queue = []; noMatches = []; failures = []

        // Counted in full before starting. The video side had a bug where the
        // total accumulated inside the loop, so a two-library run showed the
        // first library's count and the bar could never pass halfway.
        total = libraryURLs.reduce(0) { running, url in
            running + ((try? LibraryStore(at: url).fetchAllEntityProfiles()
                .filter { $0.id.hasPrefix("actor:") }.count) ?? 0)
        }

        let delay = UInt64((1.0 / max(provider.requestsPerSecond, 0.1)) * 1_000_000_000)

        for libraryURL in libraryURLs {
            guard let store = try? LibraryStore(at: libraryURL),
                  let profiles = try? store.fetchAllEntityProfiles()
                    .filter({ $0.id.hasPrefix("actor:") }) else { continue }

            for profile in profiles {
                if cancelled { break }
                current = displayName(profile)

                if let reason = ActorBatchPolicy.skipReason(for: profile) {
                    report.record(.skipped(reason: reason))
                    continue
                }

                let outcome = await examine(profile, in: libraryURL,
                                            provider: provider, store: store)
                report.record(outcome)

                switch outcome {
                case .noMatch:
                    noMatches.append(QueuedActor(profile: profile, candidates: [],
                                                 libraryURL: libraryURL))
                case .failed:
                    failures.append(QueuedActor(profile: profile, candidates: [],
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
                        // ⚠️ A non-match clears any id left from a previous run,
                        // so provenance never points at a record we are no
                        // longer matched to.
                        updated.enrichmentSourceId = nil
                    }
                    try? store.saveEntityProfile(updated)
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
                         provider: any ActorMetadataProvider,
                         store: LibraryStore) async -> ActorBatchOutcome {
        let name = displayName(profile)
        guard !name.isEmpty else { return .skipped(reason: "no name") }

        let candidates: [PluginCandidate]
        do {
            candidates = try await provider.search(name: name)
        } catch {
            return .failed(friendly(error))
        }
        guard !candidates.isEmpty else { return .noMatch }

        // ⚠️ More than one is a QUESTION, not a match. Two people share a name
        // often enough that picking the first is how a bio lands on the wrong
        // person — and the match would then be recorded, so nothing brings it
        // back for review.
        guard ActorBatchPolicy.isDecisive(candidateCount: candidates.count),
              let hit = candidates.first else {
            queue.append(QueuedActor(profile: profile, candidates: candidates,
                                     libraryURL: libraryURL))
            return .queued(candidateCount: candidates.count)
        }

        let proposal: ActorMetadataProposal
        do {
            proposal = try await provider.fetch(actorId: hit.id)
        } catch {
            return .failed(friendly(error))
        }

        let review = ActorEnrichment.review(profile: profile, proposal: proposal,
                                            sourceName: provider.displayName)
        let fields = ActorBatchPolicy.autoApplicableFields(review.changes)

        var merged = ActorEnrichment.apply(proposal, to: profile, entityId: profile.id,
                                           accepting: fields)
        // The chosen record's id IS the match. Keeping it turns every later
        // lookup from a re-search by name into a fetch.
        merged.enrichmentSourceId = hit.id
        appliedProfile = merged
        return .applied(fields: Array(fields))
    }

    private func displayName(_ profile: EntityProfile) -> String {
        profile.id.hasPrefix("actor:") ? String(profile.id.dropFirst(6)) : profile.id
    }

    private func friendly(_ error: Error) -> String {
        (error as? PluginError)?.localizedDescription ?? error.localizedDescription
    }
}
