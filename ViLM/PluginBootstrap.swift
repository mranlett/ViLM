// PluginBootstrap.swift
// The extension point. TRACKED and PUBLIC — and it names no plugin.
//
// Per the Plugin Architecture epic (D2 / D7): the public repository contains the
// extension point and nothing that uses it. No module name, no package
// reference, no evidence of which plugins exist. A package's absence from the
// dependency graph is the gate; there is no roster here to leak.
//
// To use plugins in a local build:
//   1. Add the plugin package as a dependency in Xcode (NOT committed).
//   2. Create ViLM/LocalPlugins.swift (gitignored) with:
//
//        import LibraryCore
//        extension PluginRegistry {
//            func registerLocalPlugins() {
//                // register(SomeProvider())
//            }
//        }
//
//   3. Set LOCAL_PLUGINS in an untracked xcconfig.
//
// Without those three, this compiles to a no-op and the app is exactly what it
// is today: fully local, with no plugin code and no plugin network path (T11).

import LibraryCore

enum PluginBootstrap {

    /// Called once at launch. Registers whatever this build linked — which, for
    /// the build produced from the public repository alone, is nothing.
    static func registerAll(into registry: PluginRegistry) {
        #if LOCAL_PLUGINS
        registry.registerLocalPlugins()
        #endif
    }

    /// True when this build links no plugin at all. Settings uses it to show
    /// "No plugins are available in this build" — a statement of fact, not an
    /// error and not a prompt to go and find some.
    static func isDefaultBuild(_ registry: PluginRegistry) -> Bool {
        registry.isEmpty
    }
}
