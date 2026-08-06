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
    var onClassifyTags: (() -> Void)?
    var onActorPhotoCleanup: (() -> Void)?
    var onTagCaseCleanup: (() -> Void)?
    var onReadFilenames: (() -> Void)?
    var onBatchMatchVideos: (() -> Void)?
    var onStudioConflicts: (() -> Void)?
    var onMoveVideos: (() -> Void)?
    var onBackupRestore: (() -> Void)?
    var onExportActorLibrary: (() -> Void)?
    var onImportActorLibrary: (() -> Void)?
    var onSelectAsset: ((Asset.ID) -> Void)?
    var onSelectActor: ((String) -> Void)?
    var onSelectTag: ((String) -> Void)?
    var onOpenTagGallery: (() -> Void)?

    @State private var isShowingHelp = false
    // Single-library maintenance tools are disabled while other libraries
    // are attached (the federated view spans several catalogs; each of these
    // tools is deeply single-library). Find Duplicates joins the federation
    // in a later step and loses its gate then.
    @ObservedObject private var session = LibrarySession.shared

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
                
                Section(
                    header: Text("Library"),
                    footer: Text(session.isFederated
                        ? "Move Videos and Back Up work on one library at a time — detach the attached librar\(session.attachedURLs.count == 1 ? "y" : "ies") in the sidebar to use them."
                        : "Choose which folder ViLM manages and keep it in sync with what's on disk.")
                ) {
                    toolButton("Open Library", icon: "folder.badge.plus", action: onOpenLibrary)
                    toolButton("Check for Changes", icon: "arrow.triangle.2.circlepath", action: onCheckForChanges)
                    toolButton("Move Videos Between Libraries", icon: "arrow.left.arrow.right", action: onMoveVideos)
                        .disabled(session.isFederated)
                    toolButton("Back Up & Restore", icon: "externaldrive.badge.timemachine", action: onBackupRestore)
                        .disabled(session.isFederated)
                }

                // Grouped by what the operator is trying to DO, in the order
                // the work actually happens: bring information in, correct what
                // is wrong, then look for what is still off. "Cleanup Tools"
                // had become the drawer everything landed in — eight items
                // spanning acquisition, repair and reporting, with nothing to
                // say which was which or which to reach for first.
                Section(
                    header: Text("Add Metadata"),
                    footer: Text("Run these in order. Filenames usually know more than the records do, so reading them first gives the matcher far more to work with.")
                ) {
                    // Deliberately first: this is the step that has to precede
                    // matching, and before any rename.
                    toolButton("1 · Read Filenames Into Catalogue",
                               icon: "text.magnifyingglass", action: onReadFilenames)
                    toolButton("2 · Match All Videos",
                               icon: "sparkle.magnifyingglass", action: onBatchMatchVideos)
                }

                Section(
                    header: Text("Fix Problems"),
                    footer: Text("Each finds records that are wrong rather than merely incomplete, shows them, and changes nothing until you say so.")
                ) {
                    toolButton("Repair Tag Spelling", icon: "textformat.abc", action: onTagCaseCleanup)
                    // `building.2.crop.circle.badge.questionmark` is not a real
                    // SF Symbol — it logged "No symbol named …" on every render
                    // and drew nothing, which is why this row sat oddly against
                    // its neighbours.
                    toolButton("Fix Duplicate Studios",
                               icon: "building.2",
                               action: onStudioConflicts)
                    toolButton("Remove Duplicate Actor Photos",
                               icon: "photo.stack", action: onActorPhotoCleanup)
                    toolButton("Merge Tags & Actors", icon: "paintbrush", action: onTagCleanup)
                        .disabled(session.isFederated)
                    toolButton("Classify Tags", icon: "tag.circle", action: onClassifyTags)
                        .disabled(session.isFederated)
                }

                Section(
                    header: Text("Find Problems"),
                    footer: Text(session.isFederated
                        ? "Find Duplicates scans every open library, so cross-library copies surface. File Name Audit works on one at a time — detach to use it."
                        : "These report rather than change anything.")
                ) {
                    toolButton("Find Duplicate Videos",
                               icon: "square.on.square.dashed", action: onFindDuplicates)
                    toolButton("File Name Audit",
                               icon: "doc.text.magnifyingglass", action: onAuditFileName)
                        .disabled(session.isFederated)
                }

                Section(
                    header: Text("Move Actor Data Between Libraries"),
                    footer: Text(session.isFederated
                        ? "With libraries attached, use Sync Actors in the sidebar instead — it converges them directly, no export file needed. These are for libraries that are never open together."
                        : "Moves enriched bios and photos into another copy of the library without losing work already there.")
                ) {
                    toolButton("Export Actor Library", icon: "square.and.arrow.up",
                               action: onExportActorLibrary)
                        .disabled(session.isFederated)
                    toolButton("Import and Merge Actor Library", icon: "square.and.arrow.down",
                               action: onImportActorLibrary)
                        .disabled(session.isFederated)
                }

                Section(
                    header: Text("One-off Migrations"),
                    footer: Text("Run once, when the library predates the feature. Harmless to skip.")
                ) {
                    toolButton("Migrate Episode Info", icon: "arrow.triangle.branch",
                               action: onMigrateEpisodes)
                        .disabled(session.isFederated)
                }

                // Reference and setup last: these are read once or
                // changed rarely, and they were pushing every tool below
                // the fold on a phone.
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

                Section(header: Text("Plugins")) {
                    NavigationLink {
                        PluginSettingsView(
                            registry: PluginEnvironment.registry,
                            installer: PluginEnvironment.installer(libraryURL: libraryURL)
                        )
                    } label: {
                        Label("Plugins", systemImage: "puzzlepiece.extension")
                    }
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
        .macFormSheet()
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
