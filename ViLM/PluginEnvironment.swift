// PluginEnvironment.swift
// The app's single plugin registry, and the concrete stores behind it.
//
// Names no plugin (D7) — it wires up storage and then asks PluginBootstrap to
// register whatever this build linked, which for the public build is nothing.
//
// Two different stores on purpose:
//   - enabled-state is a PREFERENCE, so UserDefaults is right
//   - a credential is a SECRET, so it goes to the Keychain and nowhere else (D6)

import Foundation
import LibraryCore

/// Persists which plugins the operator has enabled. Not secret — a plugin being
/// switched on is a preference, and storing it here keeps it out of the Keychain
/// where it would need no protection anyway.
final class UserDefaultsPluginStateStore: PluginStateStore, @unchecked Sendable {

    private let defaults: UserDefaults
    private let prefix = "plugin.enabled."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled(pluginId: String) -> Bool {
        defaults.bool(forKey: prefix + pluginId)
    }

    func setEnabled(_ enabled: Bool, pluginId: String) {
        if enabled {
            defaults.set(true, forKey: prefix + pluginId)
        } else {
            // Removed rather than set false, so an uninstall leaves no trace of
            // which plugins were ever tried.
            defaults.removeObject(forKey: prefix + pluginId)
        }
    }
}

enum PluginEnvironment {

    /// Created once, at first use. `PluginBootstrap` decides what goes in; in the
    /// build produced from the public repository alone, that is nothing.
    static let registry: PluginRegistry = {
        let registry = PluginRegistry(
            store: UserDefaultsPluginStateStore(),
            credentials: KeychainCredentialStore()
        )
        PluginBootstrap.registerAll(into: registry)
        return registry
    }()

    private static let credentials = KeychainCredentialStore()

    /// An installer bound to the current library.
    ///
    /// The response cache lives inside the library's `.catalog`, so it is
    /// per-library rather than app-wide — cached responses travel with the
    /// library they enriched. Falls back to an in-memory cache when no library
    /// is open, which cannot happen from Settings but keeps the type total.
    static func installer(libraryURL: URL?) -> PluginInstaller {
        let cache: PluginResponseCache = libraryURL.map { FileResponseCache(libraryURL: $0) }
            ?? InMemoryResponseCache()
        return PluginInstaller(registry: registry, credentials: credentials, cache: cache)
    }

    /// True when this build links no plugin at all.
    static var isDefaultBuild: Bool { PluginBootstrap.isDefaultBuild(registry) }
}
