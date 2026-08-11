// ActorBatchMatchModelTests.swift
// The bulk actor run: what it identifies, what it refuses to guess, and what
// it records along the way.
//
// ⭐ This is the highest-yield path in the app — it re-fetches every matched
// performer by known id, so one sweep re-checks the whole library at no extra
// request cost. It is also the path where an automatic wrong answer is worst:
// a batch run that guesses between two performers of one name writes a bio
// onto the wrong person, silently, hundreds of times.
//
// ⚠️ Installs a fake provider in the app's shared registry, because `provider`
// is read from it rather than injected. Registered in setUp and DISABLED in
// tearDown — a leaked provider would change the behaviour of every other suite
// in this target, which is exactly the kind of shared-state bug tests are
// supposed to catch rather than cause.

import XCTest
import LibraryCore
@testable import ViLM

@MainActor
final class ActorBatchMatchModelTests: XCTestCase {

    private var url: URL!
    private var store: LibraryStore!

    /// Answers from a script, so a run is deterministic and offline.
    private final class FakeProvider: ActorMetadataProvider, @unchecked Sendable {
        let id = "test.actor.batch"
        let displayName = "TheSource"
        let summary = ""
        let capabilities: Set<PluginCapability> = [.actorMetadata]
        let credentialRequirement: CredentialRequirement = .none
        var requestsPerSecond: Double { 1000 }   // no artificial delay in tests

        /// name → the candidates the source returns.
        var candidates: [String: [PluginCandidate]] = [:]
        var fetched: [String] = []

        func search(name: String) async throws -> [PluginCandidate] { candidates[name] ?? [] }
        func fetch(actorId: String) async throws -> ActorMetadataProposal {
            fetched.append(actorId)
            var p = ActorMetadataProposal()
            p.sourceId = .init(actorId, sourceNote: displayName)
            p.bio = .init("A biography.", sourceNote: displayName)
            return p
        }
        func knownWorks(actorId: String, limit: Int) async throws -> [PluginCandidate] { [] }
    }

    private var provider: FakeProvider!
    /// Real providers this machine has installed, disabled for the duration.
    ///
    /// 🚨 `installedActorProviders().first` returns the FIRST registered — and
    /// `PluginBootstrap` registers the real ones before any test can. Without
    /// this the suite silently exercised whatever the developer happens to
    /// have installed, which is both non-deterministic and a live network
    /// call. It cost a confusing run of failures to notice.
    private var suspended: [String] = []

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LibraryStore(at: url)
        LibrarySession.shared.setPrimary(url)

        suspended = PluginEnvironment.registry.installedActorProviders().map(\.id)
        for id in suspended { PluginEnvironment.registry.setEnabled(false, pluginId: id) }

        provider = FakeProvider()
        PluginEnvironment.registry.register(provider)
        PluginEnvironment.registry.setEnabled(true, pluginId: provider.id)

        XCTAssertEqual(PluginEnvironment.registry.installedActorProviders().first?.id,
                       provider.id, "the fake must be the one under test")
    }

    override func tearDownWithError() throws {
        // 🚨 Disabled, not merely forgotten. Left installed it would change how
        // every other suite in this target behaves.
        PluginEnvironment.registry.setEnabled(false, pluginId: "test.actor.batch")
        // Whatever this machine had installed is put back exactly as it was.
        for id in suspended { PluginEnvironment.registry.setEnabled(true, pluginId: id) }
        LibrarySession.shared.setPrimary(nil)
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func actor(_ name: String, sourceId: String? = nil) throws -> EntityProfile {
        var p = try store.newEntityProfile(named: name, type: "actor")
        p.enrichmentSourceId = sourceId
        if sourceId != nil { p.enrichmentSource = "TheSource" }
        try store.saveEntityProfile(p)
        return p
    }

    private func run() async -> ActorBatchMatchModel {
        let m = ActorBatchMatchModel(libraryURLs: [url])
        await m.run()
        return m
    }

    // MARK: - ⭐ An identity the library already holds settles it

    /// No search, no re-disambiguation. Searching again for a performer whose
    /// id is already known is how a re-guess lands on the wrong person of a
    /// shared name AFTER the right one was established.
    func testAKnownIdentityIsFetchedDirectlyWithoutSearching() async throws {
        try actor("Ann Example", sourceId: "p-ann")

        _ = await run()

        XCTAssertEqual(provider.fetched, ["p-ann"])
    }

    /// The run records what the source said about a record it DID fetch.
    ///
    /// ⚠️ The edge is written with `recordMatch`, which does not mark the
    /// profile `matched` — because a matched profile is skipped, see below.
    func testStateIsRecordedForAPerformerTheRunFetches() async throws {
        let a = try actor("Ann Example", sourceId: "p-ann")
        try store.recordMatch(NodeMatch(nodeId: a.id, source: "TheSource",
                                        sourceId: "p-ann", method: .name), isVideo: false)

        _ = await run()

        let match = try XCTUnwrap(try store.matches(forEntity: a.id).first)
        XCTAssertNotNil(match.checkedAt,
                        "a fetch that asks and does not write it down asks for nothing")
    }

    /// 🚨 A settled match is SKIPPED, and this corrects a claim I made in
    /// writing: the batch run is not a bulk re-check of the library. It is a
    /// first-identification pass, so it will never notice that an
    /// already-matched performer has gone from the source.
    ///
    /// The only bulk re-check is `Check now` on *Gone at the Source*.
    func testAnAlreadyMatchedPerformerIsSkippedEntirely() async throws {
        let a = try actor("Ann Example", sourceId: "p-ann")
        try store.confirmEntityMatch(a.id, source: "TheSource",
                                     sourceId: "p-ann", method: .name)

        _ = await run()

        XCTAssertTrue(provider.fetched.isEmpty, "matched means skipped")
        let match = try XCTUnwrap(try store.matches(forEntity: a.id).first)
        XCTAssertNil(match.checkedAt, "so nothing was re-checked about it")
    }

    // MARK: - 🚨 It never guesses between two of a name

    /// Queued for a person, not resolved automatically. A wrong auto-match is
    /// recorded and nothing brings it back for review.
    func testTwoCandidatesOfOneNameAreQueuedRatherThanChosen() async throws {
        try actor("Ann Example")
        provider.candidates["Ann Example"] = [
            .init(id: "p-1", title: "Ann Example"),
            .init(id: "p-2", title: "Ann Example"),
        ]

        let m = await run()

        XCTAssertEqual(m.queue.count, 1, "handed to the operator")
        XCTAssertTrue(provider.fetched.isEmpty, "and nothing was written for either")
    }

    /// ⭐ One exact match IS decisive — the run would be useless if every
    /// performer needed a decision.
    func testASingleExactMatchIsTakenAutomatically() async throws {
        try actor("Ann Example")
        provider.candidates["Ann Example"] = [.init(id: "p-1", title: "Ann Example")]

        _ = await run()

        XCTAssertEqual(provider.fetched, ["p-1"])
        XCTAssertEqual(try store.fetchEntityProfile(named: "Ann Example",
                                                    type: "actor")?.enrichmentSourceId, "p-1")
    }

    func testANameTheSourceDoesNotKnowIsReportedNotInvented() async throws {
        try actor("Nobody Here")

        let m = await run()

        XCTAssertEqual(m.noMatches.count, 1)
        XCTAssertTrue(provider.fetched.isEmpty)
    }

    // MARK: - The library afterwards

    func testTheRunLeavesTheLibraryCoherent() async throws {
        try actor("Ann Example", sourceId: "p-ann")
        try actor("Bea Example")
        provider.candidates["Bea Example"] = [.init(id: "p-bea", title: "Bea Example")]

        _ = await run()

        XCTAssertTrue(try store.namelessNodes().isEmpty,
                      "a bulk run must not mint a node without an identity")
        let ids = try store.fetchAllEntityProfiles().compactMap(\.enrichmentSourceId)
        XCTAssertEqual(Set(ids), ["p-ann", "p-bea"])
    }

    /// ⚠️ Running twice must not duplicate anything — the operator re-runs
    /// this whenever new actors appear.
    func testASecondRunChangesNoCounts() async throws {
        try actor("Ann Example", sourceId: "p-ann")

        _ = await run()
        let after = try store.fetchAllEntityProfiles().count
        _ = await run()

        XCTAssertEqual(try store.fetchAllEntityProfiles().count, after)
    }
}
