import XCTest
@testable import LibraryCore

private struct ServiceDouble: ActorMetadataProvider {
    let id: String
    let displayName = "Double"
    let summary = "A test double."
    var capabilities: Set<PluginCapability> { [.actorMetadata] }
    var credentialRequirement: CredentialRequirement
    func search(name: String) async throws -> [PluginCandidate] { [] }
    func fetch(actorId: String) async throws -> ActorMetadataProposal { .init() }
}

/// Tests for credentials, caching, install lifecycle and rate limiting
/// (Plugin Architecture, D6 / D3). Covers T7 and T8.
final class PluginServicesTests: XCTestCase {

    private func makeStack(credential requirement: CredentialRequirement = .none)
        -> (PluginRegistry, PluginInstaller, InMemoryCredentialStore, InMemoryResponseCache) {
        let store = InMemoryPluginStateStore()
        let creds = InMemoryCredentialStore()
        let registry = PluginRegistry(store: store, credentials: creds)
        registry.register(ServiceDouble(id: "p", credentialRequirement: requirement))
        let cache = InMemoryResponseCache()
        return (registry, PluginInstaller(registry: registry, credentials: creds, cache: cache), creds, cache)
    }

    // MARK: - T7 — credential handling

    func testInstallingWithACredentialStoresItAndCompletesInstallation() {
        let (registry, installer, creds, _) = makeStack(credential: .apiKey)
        XCTAssertEqual(installer.install(pluginId: "p", credential: "secret"), .installed)
        XCTAssertEqual(creds.credential(for: "p"), "secret")
        XCTAssertEqual(registry.state(of: "p"), .installed,
                       "registry and installer must agree — one source of truth for credentials")
    }

    func testInstallingWithoutARequiredCredentialReportsNeedsCredential() {
        let (_, installer, creds, _) = makeStack(credential: .apiKey)
        XCTAssertEqual(installer.install(pluginId: "p"), .needsCredential)
        XCTAssertNil(creds.credential(for: "p"))
    }

    func testAnEmptyCredentialIsTreatedAsNoCredential() {
        let (_, installer, _, _) = makeStack(credential: .apiKey)
        XCTAssertEqual(installer.install(pluginId: "p", credential: ""), .needsCredential,
                       "an empty string must not count as supplied")
        XCTAssertFalse(installer.hasCredential(pluginId: "p"))
    }

    func testAPluginNeedingNoCredentialInstallsWithoutOne() {
        let (_, installer, _, _) = makeStack(credential: .none)
        XCTAssertEqual(installer.install(pluginId: "p"), .installed)
    }

    func testInstallingAnUnknownPluginIsReportedRatherThanIgnored() {
        let (_, installer, _, _) = makeStack()
        XCTAssertEqual(installer.install(pluginId: "nope"), .unknownPlugin)
    }

    /// The promise an uninstall makes.
    func testUninstallClearsTheCredentialAndPurgesTheCache() {
        let (registry, installer, creds, cache) = makeStack(credential: .apiKey)
        installer.install(pluginId: "p", credential: "secret")
        cache.store(Data(repeating: 0, count: 512), pluginId: "p", requestKey: "req")
        XCTAssertEqual(installer.cacheSize(pluginId: "p"), 512)

        installer.uninstall(pluginId: "p")

        XCTAssertNil(creds.credential(for: "p"), "credential is gone")
        XCTAssertEqual(installer.cacheSize(pluginId: "p"), 0, "cache is purged")
        XCTAssertEqual(registry.state(of: "p"), .available, "back to merely available")
    }

    func testUninstallingOnePluginLeavesAnotherUntouched() {
        let store = InMemoryPluginStateStore()
        let creds = InMemoryCredentialStore()
        let registry = PluginRegistry(store: store, credentials: creds)
        registry.register(ServiceDouble(id: "a", credentialRequirement: .none))
        registry.register(ServiceDouble(id: "b", credentialRequirement: .none))
        let cache = InMemoryResponseCache()
        let installer = PluginInstaller(registry: registry, credentials: creds, cache: cache)

        installer.install(pluginId: "a", credential: "secret-a")
        installer.install(pluginId: "b", credential: "secret-b")
        cache.store(Data(repeating: 1, count: 100), pluginId: "a", requestKey: "r")
        cache.store(Data(repeating: 1, count: 200), pluginId: "b", requestKey: "r")

        installer.uninstall(pluginId: "a")

        XCTAssertNil(creds.credential(for: "a"))
        XCTAssertEqual(creds.credential(for: "b"), "secret-b", "plugins are isolated from each other")
        XCTAssertEqual(installer.cacheSize(pluginId: "b"), 200)
    }

    // MARK: - T8 — cache replay

    func testACachedResponseSatisfiesARepeatRequest() {
        let cache = InMemoryResponseCache()
        let payload = Data("recorded".utf8)
        cache.store(payload, pluginId: "p", requestKey: "search:jane")
        XCTAssertEqual(cache.data(pluginId: "p", requestKey: "search:jane"), payload)
    }

    func testTheCacheIsKeyedByPluginAndByRequest() {
        let cache = InMemoryResponseCache()
        cache.store(Data("a".utf8), pluginId: "p1", requestKey: "k")
        cache.store(Data("b".utf8), pluginId: "p2", requestKey: "k")
        XCTAssertEqual(cache.data(pluginId: "p1", requestKey: "k"), Data("a".utf8))
        XCTAssertEqual(cache.data(pluginId: "p2", requestKey: "k"), Data("b".utf8),
                       "same request key, different plugin, different entry")
        XCTAssertNil(cache.data(pluginId: "p1", requestKey: "other"))
    }

    func testCacheSizeReportsOnlyTheRequestedPlugin() {
        let cache = InMemoryResponseCache()
        cache.store(Data(repeating: 0, count: 10), pluginId: "p1", requestKey: "a")
        cache.store(Data(repeating: 0, count: 25), pluginId: "p1", requestKey: "b")
        cache.store(Data(repeating: 0, count: 99), pluginId: "p2", requestKey: "a")
        XCTAssertEqual(cache.size(pluginId: "p1"), 35)
        XCTAssertEqual(cache.size(pluginId: "p2"), 99)
    }

    func testPurgingOnePluginLeavesOthersIntact() {
        let cache = InMemoryResponseCache()
        cache.store(Data(repeating: 0, count: 10), pluginId: "p1", requestKey: "a")
        cache.store(Data(repeating: 0, count: 10), pluginId: "p2", requestKey: "a")
        cache.purge(pluginId: "p1")
        XCTAssertEqual(cache.size(pluginId: "p1"), 0)
        XCTAssertEqual(cache.size(pluginId: "p2"), 10)
    }

    // MARK: - Rate limiting

    func testTheFirstRequestIsNeverDelayed() async {
        let limiter = PluginRateLimiter()
        let delay = await limiter.delayBeforeNextRequest(pluginId: "p", requestsPerSecond: 1)
        XCTAssertEqual(delay, 0)
    }

    func testASecondRequestIsDelayedByTheDeclaredInterval() async {
        let now = Date(timeIntervalSince1970: 1000)
        let limiter = PluginRateLimiter(clock: { now })
        await limiter.recordRequest(pluginId: "p", requestsPerSecond: 2)   // 0.5s interval
        let delay = await limiter.delayBeforeNextRequest(pluginId: "p", requestsPerSecond: 2)
        XCTAssertEqual(delay, 0.5, accuracy: 0.001)
    }

    func testConsecutiveRequestsQueueRatherThanCollapse() async {
        let now = Date(timeIntervalSince1970: 1000)
        let limiter = PluginRateLimiter(clock: { now })
        for _ in 0..<3 { await limiter.recordRequest(pluginId: "p", requestsPerSecond: 1) }
        let delay = await limiter.delayBeforeNextRequest(pluginId: "p", requestsPerSecond: 1)
        XCTAssertEqual(delay, 3.0, accuracy: 0.001, "three requests reserve three seconds")
    }

    func testRateLimitsAreIndependentPerPlugin() async {
        let now = Date(timeIntervalSince1970: 1000)
        let limiter = PluginRateLimiter(clock: { now })
        await limiter.recordRequest(pluginId: "p1", requestsPerSecond: 1)
        let other = await limiter.delayBeforeNextRequest(pluginId: "p2", requestsPerSecond: 1)
        XCTAssertEqual(other, 0, "one plugin's politeness policy must not throttle another")
    }

    func testAZeroRateIsTreatedAsUnlimitedRatherThanDividingByZero() async {
        let limiter = PluginRateLimiter()
        await limiter.recordRequest(pluginId: "p", requestsPerSecond: 0)
        let delay = await limiter.delayBeforeNextRequest(pluginId: "p", requestsPerSecond: 0)
        XCTAssertEqual(delay, 0)
    }

    func testResetClearsHistorySoAReinstallIsNotThrottled() async {
        let now = Date(timeIntervalSince1970: 1000)
        let limiter = PluginRateLimiter(clock: { now })
        await limiter.recordRequest(pluginId: "p", requestsPerSecond: 1)
        await limiter.reset(pluginId: "p")
        let delay = await limiter.delayBeforeNextRequest(pluginId: "p", requestsPerSecond: 1)
        XCTAssertEqual(delay, 0)
    }

    // MARK: - Credential storage discipline

    func testTheDefaultCredentialStoreDoesNotPersist() {
        // A default that wrote to UserDefaults would be exactly the mistake D6
        // forbids, so the in-memory store is the default and this pins it.
        let a = InMemoryCredentialStore()
        a.setCredential("secret", for: "p")
        let b = InMemoryCredentialStore()
        XCTAssertNil(b.credential(for: "p"), "a fresh store shares nothing with another")
    }

    func testSettingNilRemovesACredential() {
        let store = InMemoryCredentialStore()
        store.setCredential("secret", for: "p")
        store.setCredential(nil, for: "p")
        XCTAssertNil(store.credential(for: "p"))
    }
}
