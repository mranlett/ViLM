// PluginRegistry.swift
// The extension point. Holds whatever plugins the build linked, and reports
// their installed state.
//
// Per the Plugin Architecture epic:
// - D3: available (linked) vs installed (enabled + credentialled). NOTHING
//   installs by default; an uninstalled plugin has no UI affordance and issues
//   no network request.
// - D7: the registry names no plugin. A package's absence from the dependency
//   graph is the gate.

import Foundation

/// Whether a plugin may be used.
public enum PluginState: Equatable, Sendable {
    /// Linked into this build, but not enabled by the operator.
    case available
    /// Enabled, and any required credential has been supplied.
    case installed
    /// Enabled but unusable — the credential it declared is missing.
    case needsCredential
}

/// Where enabled-state lives.
///
/// Deliberately NOT the source of truth for credentials — `PluginCredentialStore`
/// owns those. An earlier version of this protocol also answered
/// `hasCredential`, which meant the registry and the installer could disagree
/// about whether a plugin was usable. One question, one owner.
public protocol PluginStateStore: Sendable {
    func isEnabled(pluginId: String) -> Bool
    func setEnabled(_ enabled: Bool, pluginId: String)
}

/// In-memory store. The default for tests, and for a build where nothing has
/// been installed yet.
public final class InMemoryPluginStateStore: PluginStateStore, @unchecked Sendable {
    private var enabled: Set<String> = []
    private let lock = NSLock()

    public init(enabled: Set<String> = []) {
        self.enabled = enabled
    }

    public func isEnabled(pluginId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled.contains(pluginId)
    }

    public func setEnabled(_ isOn: Bool, pluginId: String) {
        lock.lock(); defer { lock.unlock() }
        if isOn { enabled.insert(pluginId) } else { enabled.remove(pluginId) }
    }

}

public final class PluginRegistry: @unchecked Sendable {

    private var plugins: [String: any Plugin] = [:]
    private var order: [String] = []
    private let store: PluginStateStore
    private let credentials: PluginCredentialStore
    private let lock = NSLock()

    public init(store: PluginStateStore = InMemoryPluginStateStore(),
                credentials: PluginCredentialStore = InMemoryCredentialStore()) {
        self.store = store
        self.credentials = credentials
    }

    // MARK: - Registration

    /// Registers a plugin. Re-registering the same id REPLACES the previous
    /// entry rather than duplicating it, so a build that links a package twice
    /// cannot produce two rows in Settings.
    public func register(_ plugin: any Plugin) {
        lock.lock(); defer { lock.unlock() }
        if plugins[plugin.id] == nil { order.append(plugin.id) }
        plugins[plugin.id] = plugin
    }

    // MARK: - Availability

    /// Every linked plugin, in registration order.
    public var available: [any Plugin] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { plugins[$0] }
    }

    public func plugin(id: String) -> (any Plugin)? {
        lock.lock(); defer { lock.unlock() }
        return plugins[id]
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return plugins.isEmpty
    }

    // MARK: - State

    public func state(of pluginId: String) -> PluginState? {
        guard let plugin = plugin(id: pluginId) else { return nil }
        guard store.isEnabled(pluginId: pluginId) else { return .available }
        if plugin.credentialRequirement != .none,
           (credentials.credential(for: plugin.credentialId) ?? "").isEmpty {
            return .needsCredential
        }
        return .installed
    }

    public func setEnabled(_ enabled: Bool, pluginId: String) {
        store.setEnabled(enabled, pluginId: pluginId)
    }

    /// Plugins that are enabled AND have whatever credential they declared.
    /// This is the ONLY list the enrichment UI may consult — an `available` but
    /// uninstalled plugin must not appear anywhere (D3).
    public var installed: [any Plugin] {
        available.filter { state(of: $0.id) == .installed }
    }

    // MARK: - Capability lookup

    /// Installed providers for a capability, in registration order.
    ///
    /// The enrichment action is absent when this is empty, goes straight to
    /// search when it has one entry, and shows a source picker when it has more.
    ///
    /// ⚠️ Presence checks only — "is anything installed at all", for showing or
    /// hiding an action. It hands back a usable provider, so anything that
    /// actually SEARCHES BY NAME must come through `actorProviders(forPerformer:in:)`
    /// instead. Same division as `installedVideoProviders()` below.
    public func installedActorProviders() -> [any ActorMetadataProvider] {
        installed.compactMap { $0 as? any ActorMetadataProvider }
    }

    /// Actor providers that may be used **for this performer**.
    ///
    /// 🚨 The privacy boundary for names (#62), and the sibling of
    /// `videoProviders(for:)`. A performer whose videos are all personal, all
    /// undeclared, or absent entirely gets an empty list — there is no provider
    /// to call, so no path exists that constructs a search and checks afterwards.
    ///
    /// ⚠️ Takes the exposure map rather than computing it, because it is one
    /// pass over every asset in the library and a batch run would otherwise pay
    /// for it per performer. The caller builds it once with
    /// `PerformerExposure.build` and **re-asks here for every performer** — a
    /// provider hoisted once for a run stays valid for every item regardless of
    /// what that item is, which is precisely the "a skipped iteration is not an
    /// exclusion" failure D10.3 names.
    public func actorProviders(forPerformer name: String,
                               in exposures: [String: PerformerExposure.Refusal?])
    -> [any ActorMetadataProvider] {
        refusalForActorLookup(ofPerformer: name, in: exposures) == nil
            ? installedActorProviders() : []
    }

    /// The same gate, phrased for a caller that wants to explain itself.
    public func refusalForActorLookup(ofPerformer name: String,
                                      in exposures: [String: PerformerExposure.Refusal?])
    -> PerformerExposure.Refusal? {
        PerformerExposure.refusal(forPerformer: name, in: exposures)
    }

    public func installedVideoProviders() -> [any VideoMetadataProvider] {
        installed.compactMap { $0 as? any VideoMetadataProvider }
    }

    /// Video providers that may be used **for this asset**.
    ///
    /// 🚨 THE privacy boundary (#59). Personal and undeclared content get an
    /// empty list, so a caller cannot obtain a provider to send them to — the
    /// refusal happens before a request can be constructed, which is the
    /// requirement. Checking inside each enrichment loop would be "a skipped
    /// iteration", and a skipped iteration is a property of one caller rather
    /// than a boundary.
    ///
    /// ⚠️ `installedVideoProviders()` above still exists because presence
    /// checks need it — "is anything installed at all", for showing or hiding
    /// an action. It hands back a usable provider, so anything that actually
    /// SENDS must come through here instead.
    public func videoProviders(for asset: Asset) -> [any VideoMetadataProvider] {
        ProviderBoundary.allows(asset.contentKind) ? installedVideoProviders() : []
    }

    /// The same gate, phrased for a caller that wants to explain itself.
    public func refusalForVideoLookup(of asset: Asset) -> ProviderBoundary.Refusal? {
        ProviderBoundary.refusal(for: asset.contentKind)
    }

    public func installedStudioProviders() -> [any StudioMetadataProvider] {
        installed.compactMap { $0 as? any StudioMetadataProvider }
    }

    public func installed(capability: PluginCapability) -> [any Plugin] {
        installed.filter { $0.capabilities.contains(capability) }
    }
}
