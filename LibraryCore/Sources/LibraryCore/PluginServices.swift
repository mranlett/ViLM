// PluginServices.swift
// Credentials, response caching and rate limiting — core services, not plugin
// responsibilities (D6).
//
// Centralising these means a plugin cannot store a credential somewhere it
// shouldn't, cannot skip the rate limit, and cannot leave data behind when it is
// uninstalled. Plugins declare requirements; core enforces them.
//
// Storage is behind protocols so tests need no Keychain and no filesystem, and
// so core assumes no particular mechanism.

import Foundation

// MARK: - Credentials

/// Where a plugin's credential lives. The Keychain implementation belongs to the
/// app target; core only needs the shape.
public protocol PluginCredentialStore: Sendable {
    func credential(for pluginId: String) -> String?
    func setCredential(_ value: String?, for pluginId: String)
    func removeCredential(for pluginId: String)
}

/// Test/default store. Deliberately in-memory: a credential must never reach
/// `UserDefaults`, a repository, or a build (D6), and an accidental default that
/// persisted would be exactly that mistake.
public final class InMemoryCredentialStore: PluginCredentialStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func credential(for pluginId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[pluginId]
    }

    public func setCredential(_ value: String?, for pluginId: String) {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { values[pluginId] = value } else { values[pluginId] = nil }
    }

    public func removeCredential(for pluginId: String) {
        setCredential(nil, for: pluginId)
    }
}

// MARK: - Response cache

/// On-disk cache of source responses, keyed by plugin id plus request hash.
///
/// Two purposes: replaying a response offline, and keeping tests network-free.
/// Purged when a plugin is uninstalled, so removing a plugin leaves nothing of
/// its data behind.
public protocol PluginResponseCache: Sendable {
    func data(pluginId: String, requestKey: String) -> Data?
    func store(_ data: Data, pluginId: String, requestKey: String)
    /// Bytes currently held for one plugin — shown on the plugin detail screen.
    func size(pluginId: String) -> Int
    func purge(pluginId: String)
    func purgeAll()
}

public final class InMemoryResponseCache: PluginResponseCache, @unchecked Sendable {
    private var entries: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    private func key(_ pluginId: String, _ requestKey: String) -> String {
        "\(pluginId)|\(requestKey)"
    }

    public func data(pluginId: String, requestKey: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries[key(pluginId, requestKey)]
    }

    public func store(_ data: Data, pluginId: String, requestKey: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key(pluginId, requestKey)] = data
    }

    public func size(pluginId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.key.hasPrefix("\(pluginId)|") }.values.reduce(0) { $0 + $1.count }
    }

    public func purge(pluginId: String) {
        lock.lock(); defer { lock.unlock() }
        for k in entries.keys where k.hasPrefix("\(pluginId)|") { entries[k] = nil }
    }

    public func purgeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}

// MARK: - Install lifecycle

/// Coordinates the states in D3 and guarantees the cleanup an uninstall promises.
///
/// The registry answers *what state is this in*; this type performs the
/// transitions and owns the side effects, so "uninstall clears the credential and
/// purges the cache" is implemented once rather than per screen.
public final class PluginInstaller: @unchecked Sendable {

    private let registry: PluginRegistry
    private let credentials: PluginCredentialStore
    private let cache: PluginResponseCache

    public init(registry: PluginRegistry,
                credentials: PluginCredentialStore = InMemoryCredentialStore(),
                cache: PluginResponseCache = InMemoryResponseCache()) {
        self.registry = registry
        self.credentials = credentials
        self.cache = cache
    }

    public enum InstallResult: Equatable, Sendable {
        case installed
        /// Enabled, but the declared credential is still missing.
        case needsCredential
        case unknownPlugin
    }

    /// Installs a plugin, optionally supplying its credential in the same step.
    @discardableResult
    public func install(pluginId: String, credential: String? = nil) -> InstallResult {
        guard let plugin = registry.plugin(id: pluginId) else { return .unknownPlugin }
        if let credential { credentials.setCredential(credential, for: pluginId) }
        registry.setEnabled(true, pluginId: pluginId)

        if plugin.credentialRequirement != .none,
           (credentials.credential(for: pluginId) ?? "").isEmpty {
            return .needsCredential
        }
        return .installed
    }

    /// Uninstalls, clearing the credential and purging the cache.
    ///
    /// Both side effects are the point: an uninstalled plugin must leave nothing
    /// behind, or "remove" is a lie the Settings screen tells.
    public func uninstall(pluginId: String) {
        registry.setEnabled(false, pluginId: pluginId)
        credentials.removeCredential(for: pluginId)
        cache.purge(pluginId: pluginId)
    }

    public func cacheSize(pluginId: String) -> Int { cache.size(pluginId: pluginId) }
    public func purgeCache(pluginId: String) { cache.purge(pluginId: pluginId) }
    public func hasCredential(pluginId: String) -> Bool {
        !(credentials.credential(for: pluginId) ?? "").isEmpty
    }
}

// MARK: - Rate limiting

/// Enforces a plugin's declared request rate.
///
/// Declared by the plugin, enforced by core (D6) — a plugin cannot opt out of
/// its own politeness policy by forgetting to implement it.
public actor PluginRateLimiter {

    private var nextAllowed: [String: Date] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    /// How long a caller must wait before issuing this plugin's next request.
    /// Returns 0 when it may proceed immediately.
    public func delayBeforeNextRequest(pluginId: String, requestsPerSecond: Double) -> TimeInterval {
        guard requestsPerSecond > 0 else { return 0 }
        let now = clock()
        guard let allowed = nextAllowed[pluginId], allowed > now else { return 0 }
        return allowed.timeIntervalSince(now)
    }

    /// Records that a request is being made, reserving the next slot.
    public func recordRequest(pluginId: String, requestsPerSecond: Double) {
        guard requestsPerSecond > 0 else { return }
        let interval = 1.0 / requestsPerSecond
        let base = max(clock(), nextAllowed[pluginId] ?? .distantPast)
        nextAllowed[pluginId] = base.addingTimeInterval(interval)
    }

    /// Clears state for one plugin — used on uninstall so a reinstall is not
    /// throttled by history.
    public func reset(pluginId: String) {
        nextAllowed[pluginId] = nil
    }
}
