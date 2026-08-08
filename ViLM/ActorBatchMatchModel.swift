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

    /// Takes an actor off the run's lists once the operator has acted on it.
    ///
    /// ⚠️ Added 2026-08-06. `VideoBatchMatchModel` has always had this and the
    /// actor screen never did, so an actor matched from the queue stayed on the
    /// "need you to choose" list for the rest of the session — settled
    /// everywhere except the screen that asked the question. The same defect
    /// was reported against the studio run.
    ///
    /// Clears the other lists too: one record can sit in more than one, and
    /// half-removing it is how a row comes back with no explanation.
    func removeFromQueue(_ profileId: String) {
        queue.removeAll { $0.profile.id == profileId }
        noMatches.removeAll { $0.profile.id == profileId }
        failures.removeAll { $0.profile.id == profileId }
    }

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
            running + ((try? LibraryStore(at: url)).map { examinable(in: $0).count } ?? 0)
        }

        let delay = UInt64((1.0 / max(provider.requestsPerSecond, 0.1)) * 1_000_000_000)

        for libraryURL in libraryURLs {
            guard let store = try? LibraryStore(at: libraryURL) else { continue }
            let profiles = examinable(in: store)
            existingProfileIds = Set(((try? store.fetchAllEntityProfiles()) ?? []).map(\.id))

            // ⭐ Actors whose identity was handed down by a video match and
            // never looked up. They read as `matched` and hold nothing else, so
            // without this they are skipped forever. Read ONCE per library
            // rather than per actor — it is a whole-table query.
            let awaitingEnrichment = (try? store.entityIdsAwaitingEnrichment()) ?? []

            for profile in profiles {
                if cancelled { break }
                current = displayName(profile)

                if let reason = ActorBatchPolicy.skipReason(
                    for: profile,
                    identityNeedsEnrichment: awaitingEnrichment.contains(profile.id)) {
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
                // 🚨 A name with no profile row becomes a PERSON only when the
                // source actually confirms one. Recording "no match" or
                // "ambiguous" against it would mint a row for a name that may
                // have been guessed from a filename — which is the one thing
                // the Epic forbids (D3), and which would then let Connect the
                // Graph wire credits to a person nobody has verified exists.
                //
                // Existing rows behave exactly as before.
                let isStandIn = !existingProfileIds.contains(profile.id)
                let mayPersist: Bool = {
                    if case .applied = outcome { return true }
                    return !isStandIn
                }()

                if let state = outcome.recordedState, mayPersist {
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

                    // The match edge as well as the columns (v31). An actor is
                    // matched by an EXACT name plus a disambiguation, which is
                    // neither a title guess nor a cast search — see
                    // `MatchMethod.name`.
                    if case .applied = outcome, let sourceId = updated.enrichmentSourceId {
                        try? store.recordMatch(
                            NodeMatch(nodeId: updated.id, source: provider.displayName,
                                      sourceId: sourceId, method: .name),
                            isVideo: false)
                    } else if case .applied = outcome {} else {
                        // ⚠️ The edge goes when the id does. A non-match that
                        // cleared the column but left the edge would leave the
                        // graph asserting an identity the node no longer claims.
                        try? store.removeMatch(nodeId: updated.id,
                                               source: provider.displayName, isVideo: false)
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

    /// Every actor the run should look at — **by name**, not by profile row.
    ///
    /// 🚨 This used to be `fetchAllEntityProfiles().filter { actor: }`, and a
    /// cast member added by a video match creates **no profile row**. So the
    /// people most in need of matching were not skipped, they were INVISIBLE:
    /// the run examined only the already-matched profiles and reported "100%
    /// skipped" while a hundred names sat at *Not yet checked* in the gallery,
    /// which builds its list from the strings instead.
    ///
    /// Reported from the device, 2026-08-07. It is the same root cause as
    /// Connect the Graph's *"190 names have no profile"*.
    private func examinable(in store: LibraryStore) -> [EntityProfile] {
        let profiles = (try? store.fetchAllEntityProfiles()) ?? []
        var byId = Dictionary(uniqueKeysWithValues:
            profiles.filter { $0.id.hasPrefix("actor:") }.map { ($0.id, $0) })

        for asset in (try? store.fetchAllAssets()) ?? [] {
            for name in asset.actors where !name.isEmpty {
                let id = "actor:\(name)"
                // A stand-in, never saved unless a match is actually applied.
                if byId[id] == nil { byId[id] = EntityProfile(id: id) }
            }
        }
        return byId.values.sorted { $0.id < $1.id }
    }

    /// Ids that already exist as rows, so the run knows which of its subjects
    /// are real records and which are names it is standing in for.
    private var existingProfileIds: Set<String> = []

    /// Carries the merged profile out of `examine` without widening the
    /// outcome type, which only the report needs to understand.
    private var appliedProfile: EntityProfile?

    private func examine(_ profile: EntityProfile, in libraryURL: URL,
                         provider: any ActorMetadataProvider,
                         store: LibraryStore) async -> ActorBatchOutcome {
        let name = displayName(profile)
        guard !name.isEmpty else { return .skipped(reason: "no name") }

        // ⭐ An identity the library already holds settles it outright.
        //
        // 🚨 This used to search by name unconditionally, so a performer whose
        // id was already known — because a matched video's source record linked
        // straight to them — was searched for again and re-disambiguated.
        // Where two people share a name, that re-guess could land on the wrong
        // one AFTER the right one was already established.
        //
        // A known id is a fetch, not a search: no candidates, nothing to
        // disambiguate, and nothing to queue.
        let resolvedId: String
        if let known = profile.enrichmentSourceId?
            .trimmingCharacters(in: .whitespacesAndNewlines), !known.isEmpty {
            resolvedId = known
        } else {
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
            resolvedId = hit.id
        }

        let proposal: ActorMetadataProposal
        do {
            proposal = try await provider.fetch(actorId: resolvedId)
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
        merged.enrichmentSourceId = resolvedId
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
