// PluginSettingsView.swift
// Settings → Plugins (epic, "Settings — Plugins screen").
//
// Lists what this build linked, and lets the operator install, configure and
// remove each one. Names no plugin: everything on screen comes from the
// registry, so this file is safe in the public repository (D7).
//
// D3 is the rule this screen enforces: nothing installs by default, and an
// uninstalled plugin has no affordance anywhere else in the app.

import SwiftUI
import LibraryCore

struct PluginSettingsView: View {
    let registry: PluginRegistry
    let installer: PluginInstaller

    /// Bumped after any install/remove so the rows re-read state from the
    /// registry. The registry is the source of truth; this view holds none.
    @State private var revision = 0

    var body: some View {
        Group {
            if registry.isEmpty {
                ContentUnavailableView(
                    "No Plugins Available",
                    systemImage: "puzzlepiece.extension",
                    // A statement of fact — not an error, and not a prompt to go
                    // and find some. The default build links none by design.
                    description: Text("No plugins are available in this build.")
                )
            } else {
                List {
                    Section {
                        ForEach(registry.available, id: \.id) { plugin in
                            NavigationLink {
                                PluginDetailView(plugin: plugin,
                                                 registry: registry,
                                                 installer: installer,
                                                 onChange: { revision += 1 })
                            } label: {
                                row(for: plugin)
                            }
                        }
                    } footer: {
                        Text("Plugins enrich your library from external sources. "
                             + "Nothing is enabled until you install it.")
                    }
                }
            }
        }
        .navigationTitle("Plugins")
        .id(revision)
    }

    private func row(for plugin: any Plugin) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(plugin.displayName).font(.body)
                Spacer()
                stateBadge(registry.state(of: plugin.id))
            }
            Text(plugin.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateBadge(_ state: PluginState?) -> some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.green)
        case .needsCredential:
            Label("Needs setup", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.orange)
        case .available, .none:
            EmptyView()
        }
    }
}

// MARK: - Detail

struct PluginDetailView: View {
    let plugin: any Plugin
    let registry: PluginRegistry
    let installer: PluginInstaller
    var onChange: () -> Void = {}

    @State private var credential = ""
    @State private var revision = 0
    @State private var isConfirmingRemove = false

    private var state: PluginState? { registry.state(of: plugin.id) }
    private var isInstalled: Bool { state == .installed }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Enriches", value: capabilityText)
                if let attribution = plugin.attribution {
                    LabeledContent("Attribution", value: attribution)
                }
                if let homepage = plugin.homepage {
                    Link("Source", destination: homepage)
                }
                Text(plugin.summary).font(.footnote).foregroundStyle(.secondary)
            }

            // Stated plainly, once, at install time (D8): what leaves the device.
            if !isInstalled {
                Section("Before you install") {
                    Label(privacyNotice, systemImage: "info.circle")
                        .font(.footnote)
                }
            }

            if plugin.credentialRequirement != .none {
                Section(credentialTitle) {
                    SecureField(credentialTitle, text: $credential)
                        .textContentType(.password)
#if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
#endif
                    if installer.hasCredential(pluginId: plugin.id) {
                        Label("Stored in your Keychain", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if isInstalled || state == .needsCredential {
                    LabeledContent("Cached responses",
                                   value: ByteCountFormatter.string(
                                    fromByteCount: Int64(installer.cacheSize(pluginId: plugin.id)),
                                    countStyle: .file))
                    Button("Clear Cache") {
                        installer.purgeCache(pluginId: plugin.id)
                        revision += 1
                    }
                    Button("Remove Plugin", role: .destructive) { isConfirmingRemove = true }
                } else {
                    Button("Install") {
                        installer.install(pluginId: plugin.id,
                                          credential: credential.isEmpty ? nil : credential)
                        credential = ""
                        revision += 1
                        onChange()
                    }
                }
            }
        }
        .navigationTitle(plugin.displayName)
        .id(revision)
        .confirmationDialog("Remove \(plugin.displayName)?",
                            isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                installer.uninstall(pluginId: plugin.id)
                credential = ""
                revision += 1
                onChange()
            }
        } message: {
            Text("This clears its saved credential and deletes its cached responses. "
                 + "Nothing already added to your library is removed.")
        }
    }

    private var capabilityText: String {
        var parts: [String] = []
        if plugin.capabilities.contains(.videoMetadata) { parts.append("Videos") }
        if plugin.capabilities.contains(.actorMetadata) { parts.append("Actors") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " and ")
    }

    private var credentialTitle: String {
        plugin.credentialRequirement == .apiKey ? "API Key" : "Access Token"
    }

    private var privacyNotice: String {
        let what = plugin.capabilities.contains(.videoMetadata)
            ? (plugin.capabilities.contains(.actorMetadata) ? "video titles and actor names" : "video titles")
            : "actor names"
        let attributable = plugin.credentialRequirement == .none
            ? "The request is anonymous."
            : "Requests are authenticated, so they are attributable to your account with that source."
        return "Installing this sends \(what) from your library to an external source when you use it. "
             + attributable
             + " Nothing is sent until you install it, and nothing is sent in the background."
    }
}
