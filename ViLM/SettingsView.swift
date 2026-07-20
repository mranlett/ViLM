// SettingsView.swift
// The Settings sheet: startup preference, Library Statistics and Help entry
// points, the library-management tools, and Actor Library Merge - each tool
// opens via a callback owned by ContentView.

import SwiftUI
import LibraryCore

struct SettingsView: View {
    @AppStorage("defaultHomePage") private var defaultHomePage: String = "dashboard"
    @Environment(\.dismiss) private var dismiss
    
    var libraryURL: URL?
    
    var onOpenLibrary: (() -> Void)?
    var onCheckForChanges: (() -> Void)?
    var onAuditFileName: (() -> Void)?
    var onFindDuplicates: (() -> Void)?
    var onMigrateEpisodes: (() -> Void)?
    var onTagCleanup: (() -> Void)?
    var onMoveVideos: (() -> Void)?
    var onBackupRestore: (() -> Void)?
    var onExportActorLibrary: (() -> Void)?
    var onImportActorLibrary: (() -> Void)?
    var onSelectAsset: ((Asset.ID) -> Void)?
    var onSelectActor: ((String) -> Void)?
    var onSelectTag: ((String) -> Void)?
    var onOpenTagGallery: (() -> Void)?

    @State private var isShowingHelp = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Startup Preferences")) {
                    Picker("Default Home Page", selection: $defaultHomePage) {
                        Text("Dashboard").tag("dashboard")
                        Text("All Assets").tag("allAssets")
                        Text("Actors Gallery").tag("actorGallery")
                        Text("Tags Gallery").tag("tagGallery")
                    }
                }
                
                Section(header: Text("Information")) {
                    NavigationLink {
                        // Deep-link handlers fire immediately; ContentView
                        // defers the navigation until the sheet's onDismiss,
                        // so no timing guess is involved.
                        LibraryStatsView(
                            libraryURL: libraryURL,
                            onSelectAsset: { onSelectAsset?($0) },
                            onSelectActor: { onSelectActor?($0) },
                            onSelectTag: { onSelectTag?($0) },
                            onOpenTagGallery: { onOpenTagGallery?() }
                        )
                    } label: {
                        Label("Library Statistics", systemImage: "chart.bar.doc.horizontal")
                    }

                    Button(action: { isShowingHelp = true }) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                }
                
                Section(
                    header: Text("Library"),
                    footer: Text("Choose which folder ViLM manages and keep it in sync with what's on disk.")
                ) {
                    toolButton("Open Library", icon: "folder.badge.plus", action: onOpenLibrary)
                    toolButton("Check for Changes", icon: "arrow.triangle.2.circlepath", action: onCheckForChanges)
                    toolButton("Move Videos Between Libraries", icon: "arrow.left.arrow.right", action: onMoveVideos)
                    toolButton("Back Up & Restore", icon: "externaldrive.badge.timemachine", action: onBackupRestore)
                }

                Section(
                    header: Text("Cleanup Tools"),
                    footer: Text("Find and fix inconsistent or duplicated data across the whole library.")
                ) {
                    toolButton("File Name Audit", icon: "text.magnifyingglass", action: onAuditFileName)
                    toolButton("Find Duplicates", icon: "square.on.square.dashed", action: onFindDuplicates)
                    toolButton("Migrate Episode Info", icon: "arrow.triangle.branch", action: onMigrateEpisodes)
                    toolButton("Tag & Actor Cleanup", icon: "paintbrush", action: onTagCleanup)
                }

                Section(
                    header: Text("Actors"),
                    footer: Text("Export and Import move enriched actor bios and photos between library copies (e.g. a portable copy) without losing existing work.")
                ) {
                    toolButton("Export Actor Library For Merge", icon: "square.and.arrow.up", action: onExportActorLibrary)
                    toolButton("Import and Merge Actor Library", icon: "square.and.arrow.down", action: onImportActorLibrary)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { isShowingHelp = true }) {
                        Image(systemName: "questionmark.circle")
                    }
                    .help("Help")
                    .accessibilityLabel("Help")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isShowingHelp) {
                HelpView(initialTopicID: HelpContent.settings.id)
            }
        }
        .frame(minWidth: 300, minHeight: 300)
    }

    // Every tool row behaves the same way: close Settings, then hand off to
    // the callback ContentView wired up (which presents the tool's sheet).
    private func toolButton(_ title: String, icon: String, action: (() -> Void)?) -> some View {
        Button(action: {
            dismiss()
            action?()
        }) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.plain)
    }
}
