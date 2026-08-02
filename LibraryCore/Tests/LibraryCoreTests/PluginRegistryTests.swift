import XCTest
@testable import LibraryCore

// MARK: - Test doubles
//
// TWO independent doubles, deliberately. D4 claims a second plugin requires no
// core change; a suite built around a single provider would never test that.
// Neither double names a real source — they are shapes, not implementations.

private struct DoubleActorProvider: ActorMetadataProvider {
    let id: String
    let displayName: String
    var summary = "A test double."
    var capabilities: Set<PluginCapability> { [.actorMetadata] }
    var credentialRequirement: CredentialRequirement = .none

    /// Records calls so tests can assert an uninstalled plugin is never reached.
    final class Log: @unchecked Sendable {
        private(set) var searches = 0
        private(set) var fetches = 0
        func search() { searches += 1 }
        func fetch() { fetches += 1 }
    }
    let log = Log()

    func search(name: String) async throws -> [PluginCandidate] {
        log.search()
        return [PluginCandidate(id: "\(id)-1", title: name, subtitle: "double")]
    }

    func fetch(actorId: String) async throws -> ActorMetadataProposal {
        log.fetch()
        var p = ActorMetadataProposal()
        p.bio = ProposedField("bio from \(id)", sourceNote: displayName)
        return p
    }
}

private struct DoubleVideoProvider: VideoMetadataProvider {
    let id: String
    let displayName: String
    var summary = "A test double."
    var capabilities: Set<PluginCapability> { [.videoMetadata] }
    var credentialRequirement: CredentialRequirement = .apiKey

    func search(title: String, year: Int?) async throws -> [PluginCandidate] {
        [PluginCandidate(id: "\(id)-1", title: title, subtitle: year.map(String.init))]
    }

    func fetch(videoId: String) async throws -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.title = ProposedField("title from \(id)")
        return p
    }
}

/// Implements BOTH provider protocols — the "combined capability" case the epic
/// anticipates in its plugin inventory.
private struct DoubleCombinedProvider: ActorMetadataProvider, VideoMetadataProvider {
    let id = "double.combined"
    let displayName = "Combined Double"
    var summary = "Implements both provider protocols."
    var capabilities: Set<PluginCapability> { [.actorMetadata, .videoMetadata] }
    var credentialRequirement: CredentialRequirement = .none

    func search(name: String) async throws -> [PluginCandidate] { [] }
    func fetch(actorId: String) async throws -> ActorMetadataProposal { .init() }
    func search(title: String, year: Int?) async throws -> [PluginCandidate] { [] }
    func fetch(videoId: String) async throws -> VideoMetadataProposal { .init() }
}

// MARK: - Tests

final class PluginRegistryTests: XCTestCase {

    /// Returns the registry plus both stores, since enabled-state and credentials
    /// are deliberately separate owners.
    private func makeRegistry() -> (PluginRegistry, InMemoryPluginStateStore, InMemoryCredentialStore) {
        let store = InMemoryPluginStateStore()
        let creds = InMemoryCredentialStore()
        return (PluginRegistry(store: store, credentials: creds), store, creds)
    }

    // MARK: - T1 / T11 — a build with no plugins

    func testAnEmptyRegistryIsTheDefaultAndExposesNothing() {
        let (registry, _, _) = makeRegistry()
        XCTAssertTrue(registry.isEmpty, "a build linking no packages has no plugins")
        XCTAssertEqual(registry.available.count, 0)
        XCTAssertEqual(registry.installed.count, 0)
        XCTAssertEqual(registry.installedActorProviders().count, 0)
        XCTAssertEqual(registry.installedVideoProviders().count, 0)
        XCTAssertNil(registry.state(of: "anything"))
    }

    // MARK: - D3 — nothing installs by default

    func testARegisteredPluginIsAvailableButNOTInstalled() {
        let (registry, _, _) = makeRegistry()
        registry.register(DoubleActorProvider(id: "a", displayName: "A"))
        XCTAssertEqual(registry.available.count, 1, "linked, so available")
        XCTAssertEqual(registry.state(of: "a"), .available)
        XCTAssertEqual(registry.installed.count, 0, "but NOT installed — nothing installs by default")
    }

    func testAnUninstalledPluginIsNeverOfferedToTheEnrichmentUI() {
        let (registry, _, _) = makeRegistry()
        registry.register(DoubleActorProvider(id: "a", displayName: "A"))
        registry.register(DoubleVideoProvider(id: "v", displayName: "V"))
        XCTAssertEqual(registry.installedActorProviders().count, 0)
        XCTAssertEqual(registry.installedVideoProviders().count, 0)
        XCTAssertEqual(registry.installed(capability: .actorMetadata).count, 0)
    }

    /// T3 — uninstalled means inert. The registry must never hand out a provider
    /// that could issue a request.
    func testAnUninstalledPluginIsNeverInvoked() async throws {
        let (registry, store, creds) = makeRegistry()
        let plugin = DoubleActorProvider(id: "a", displayName: "A")
        registry.register(plugin)

        for provider in registry.installedActorProviders() {
            _ = try await provider.search(name: "anyone")
        }
        XCTAssertEqual(plugin.log.searches, 0, "an uninstalled plugin must issue NO request")

        store.setEnabled(true, pluginId: "a")
        for provider in registry.installedActorProviders() {
            _ = try await provider.search(name: "anyone")
        }
        XCTAssertEqual(plugin.log.searches, 1, "and exactly one once installed")
    }

    // MARK: - Credential gating

    func testAPluginNeedingACredentialIsNotInstalledUntilOneExists() {
        let (registry, store, creds) = makeRegistry()
        registry.register(DoubleVideoProvider(id: "v", displayName: "V"))   // .apiKey

        store.setEnabled(true, pluginId: "v")
        XCTAssertEqual(registry.state(of: "v"), .needsCredential,
                       "enabled but unusable is its own state, not 'installed'")
        XCTAssertEqual(registry.installed.count, 0)

        creds.setCredential("secret", for: "v")
        XCTAssertEqual(registry.state(of: "v"), .installed)
        XCTAssertEqual(registry.installed.count, 1)
    }

    func testAPluginNeedingNoCredentialInstallsOnEnableAlone() {
        let (registry, store, creds) = makeRegistry()
        registry.register(DoubleActorProvider(id: "a", displayName: "A"))   // .none
        store.setEnabled(true, pluginId: "a")
        XCTAssertEqual(registry.state(of: "a"), .installed)
    }

    func testRemovingACredentialReturnsAPluginToNeedsCredential() {
        let (registry, store, creds) = makeRegistry()
        registry.register(DoubleVideoProvider(id: "v", displayName: "V"))
        store.setEnabled(true, pluginId: "v")
        creds.setCredential("secret", for: "v")
        XCTAssertEqual(registry.state(of: "v"), .installed)

        creds.setCredential(nil, for: "v")
        XCTAssertEqual(registry.state(of: "v"), .needsCredential)
        XCTAssertEqual(registry.installedVideoProviders().count, 0)
    }

    func testDisablingReturnsAPluginToAvailable() {
        let (registry, store, creds) = makeRegistry()
        registry.register(DoubleActorProvider(id: "a", displayName: "A"))
        store.setEnabled(true, pluginId: "a")
        XCTAssertEqual(registry.state(of: "a"), .installed)
        registry.setEnabled(false, pluginId: "a")
        XCTAssertEqual(registry.state(of: "a"), .available)
    }

    // MARK: - T9 — a second provider is a drop-in

    func testASecondProviderRegistersWithNoCoreChange() {
        let (registry, store, creds) = makeRegistry()
        registry.register(DoubleActorProvider(id: "a1", displayName: "First"))
        registry.register(DoubleActorProvider(id: "a2", displayName: "Second"))
        store.setEnabled(true, pluginId: "a1")
        store.setEnabled(true, pluginId: "a2")

        XCTAssertEqual(registry.installedActorProviders().count, 2,
                       "two providers for one capability coexist")
        XCTAssertEqual(registry.installedActorProviders().map(\.id), ["a1", "a2"],
                       "registration order is preserved, so a picker is stable")
    }

    func testProvidersAreSeparatedByCapability() {
        let (registry, store, creds) = makeRegistry()
        registry.register(DoubleActorProvider(id: "a", displayName: "A"))
        registry.register(DoubleVideoProvider(id: "v", displayName: "V"))
        store.setEnabled(true, pluginId: "a")
        store.setEnabled(true, pluginId: "v")
        creds.setCredential("secret", for: "v")

        XCTAssertEqual(registry.installedActorProviders().map(\.id), ["a"])
        XCTAssertEqual(registry.installedVideoProviders().map(\.id), ["v"])
    }

    func testOnePluginMayImplementBothProviderProtocols() {
        let (registry, store, creds) = makeRegistry()
        registry.register(DoubleCombinedProvider())
        store.setEnabled(true, pluginId: "double.combined")

        XCTAssertEqual(registry.installedActorProviders().count, 1)
        XCTAssertEqual(registry.installedVideoProviders().count, 1)
        XCTAssertEqual(registry.installed.count, 1, "still ONE plugin, listed once in Settings")
    }

    // MARK: - Registration hygiene

    func testRegisteringTheSameIdTwiceReplacesRatherThanDuplicates() {
        let (registry, _, _) = makeRegistry()
        registry.register(DoubleActorProvider(id: "a", displayName: "First"))
        registry.register(DoubleActorProvider(id: "a", displayName: "Second"))
        XCTAssertEqual(registry.available.count, 1, "no duplicate row in Settings")
        XCTAssertEqual(registry.available.first?.displayName, "Second", "last registration wins")
    }

    func testLookupByIdReturnsNilForAnUnknownPlugin() {
        let (registry, _, _) = makeRegistry()
        XCTAssertNil(registry.plugin(id: "nope"))
    }

    // MARK: - Proposal semantics (D5's foundation)

    func testAnAbsentFieldIsDistinctFromAnEmptyOne() {
        let absent = ProposedField<String>.absent
        let empty = ProposedField<String>("")
        XCTAssertNil(absent.value, "the source said nothing")
        XCTAssertEqual(empty.value, "", "the source said 'empty' — a different claim")
        XCTAssertNotEqual(absent, empty,
                          "core must be able to tell these apart, or a silent source clears fields")
    }

    func testAFreshProposalProposesNothingAtAll() {
        let actor = ActorMetadataProposal()
        XCTAssertNil(actor.bio.value)
        XCTAssertNil(actor.akas.value)
        XCTAssertNil(actor.careerEndYear.value)
        let video = VideoMetadataProposal()
        XCTAssertNil(video.title.value)
        XCTAssertNil(video.actors.value)
    }

    func testAProposedFieldCarriesItsSourceNoteForTheReviewSheet() {
        let f = ProposedField("Brown", sourceNote: "Example Source")
        XCTAssertEqual(f.value, "Brown")
        XCTAssertEqual(f.sourceNote, "Example Source")
    }

    // MARK: - Contract shape

    func testPluginDefaultsKeepTheProtocolCheapToAdopt() {
        let p = DoubleActorProvider(id: "a", displayName: "A")
        XCTAssertNil(p.attribution, "attribution is optional")
        XCTAssertNil(p.homepage, "homepage is optional")
        XCTAssertEqual(p.requestsPerSecond, 1.0, "a conservative default rate limit")
    }

    func testAVideoProviderNeedNotImplementArtwork() async throws {
        let p = DoubleVideoProvider(id: "v", displayName: "V")
        let art = try await p.artwork(videoId: "anything")
        XCTAssertEqual(art, [], "the default returns none rather than forcing an implementation")
    }

    func testCapabilitiesAndCredentialRequirementsAreEnumerable() {
        XCTAssertEqual(Set(PluginCapability.allCases), [.videoMetadata, .actorMetadata])
        XCTAssertEqual(Set(CredentialRequirement.allCases), [.none, .apiKey, .token])
    }
}
