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
    var onAliasSplits: (() -> Void)?
    var onRefreshMatched: (() -> Void)?
    var onTagCaseCleanup: (() -> Void)?
    var onReadFilenames: (() -> Void)?
    var onBatchMatchVideos: (() -> Void)?
    var onBatchMatchActors: (() -> Void)?
    var onBatchMatchStudios: (() -> Void)?
    var onStudioConflicts: (() -> Void)?
    var onStudioAudit: (() -> Void)?
    var onGraphAudit: (() -> Void)?
    var onConnectGraph: (() -> Void)?
    var onResetMatches: (() -> Void)?
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
                    toolButton("3 · Match All Actors",
                               icon: "person.crop.circle.badge.checkmark",
                               action: onBatchMatchActors)
                    // Last of the four because it benefits from the others
                    // having run: a studio with no videos left carrying two
                    // names has nothing ambiguous to confirm.
                    // ⚠️ `building.2.crop.circle`, NOT a `.badge.checkmark`
                    // variant. The `person.crop.circle.badge.checkmark` used
                    // above exists; the building equivalent does not, and
                    // SwiftUI renders a missing symbol as nothing at all — so
                    // this row silently lost its icon and sat offset from its
                    // three neighbours.
                    toolButton("4 · Match All Studios",
                               icon: "building.2.crop.circle",
                               action: onBatchMatchStudios)
                    // ⭐ Fifth because it is only worth running once the first
                    // four have. It re-reads videos those runs SKIPPED as
                    // "already matched", which is the one route by which a
                    // library matched before a field existed can ever gain it.
                    toolButton("5 · Refresh Matched Videos",
                               icon: "arrow.clockwise.circle",
                               action: onRefreshMatched)
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
                    // ⚠️ One library only, like the other profile-mutating
                    // tools. Attached, the audit reads the MAIN library alone —
                    // so a performer with twenty videos in the other library
                    // reads as having none, and "0 videos" is the strongest
                    // argument for merging a profile away. It would argue for
                    // deleting exactly the wrong half.
                    toolButton("Merge Duplicate Performers",
                               icon: "person.2.badge.gearshape", action: onAliasSplits)
                        .disabled(session.isFederated)
                    toolButton("Remove Duplicate Actor Photos",
                               icon: "photo.stack", action: onActorPhotoCleanup)
                    toolButton("Remove Orphaned Profiles", icon: "trash.slash", action: onTagCleanup)
                        .disabled(session.isFederated)
                    toolButton("Classify Tags", icon: "tag.circle", action: onClassifyTags)
                        .disabled(session.isFederated)
                }

                Section(
                    header: Text("Build the Graph"),
                    footer: Text(session.isFederated
                        ? "Edges live inside one library and point at rows in it, so there is nothing an edge spanning two could mean. Detach to use this."
                        : "Adds a structured copy of what the tags already say, so the app can ask questions the text cannot answer. Your tags are left exactly as they are.")
                ) {
                    toolButton("Connect the Graph",
                               icon: "point.3.connected.trianglepath.dotted",
                               action: onConnectGraph)
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
                    // Single-library for the same reason Connect the Graph is:
                    // half of what it checks is edges, and an edge cannot span
                    // two libraries.
                    // `checklist` rather than a building: the other two studio
                    // rows in Settings already take `building.2` and
                    // `building.2.crop.circle`, and three near-identical
                    // buildings in one Settings screen is three rows nobody can
                    // tell apart at a glance.
                    toolButton("Studio Health",
                               icon: "checklist", action: onStudioAudit)
                        .disabled(session.isFederated)
                    // Cross-record checks: a video's date against a performer's
                    // birth date or recorded career. Finds data that is WRONG,
                    // where the others find data that is missing.
                    toolButton("Impossible Data",
                               icon: "exclamationmark.magnifyingglass", action: onGraphAudit)
                        .disabled(session.isFederated)
                }

                Section(
                    header: Text("Move the Graph Between Libraries"),
                    footer: Text(session.isFederated
                        ? "With libraries attached, use Sync Actors in the sidebar instead — it converges them directly, no export file needed. These are for libraries that are never open together."
                        : "Carries actors, studios, the tag vocabulary and the connections between them into another library — everything except the videos, which stay where they are. Additive: nothing already there is removed.")
                ) {
                    toolButton("Export Graph", icon: "square.and.arrow.up",
                               action: onExportActorLibrary)
                        .disabled(session.isFederated)
                    toolButton("Import & Merge Graph", icon: "square.and.arrow.down",
                               action: onImportActorLibrary)
                        .disabled(session.isFederated)
                }

                // Rare, and one of them destructive. Kept together and out
                // of the everyday flow rather than sitting beside tools reached
                // weekly — Match Again in particular was one row below Connect
                // the Graph, which is the tool it most resembles and least
                // resembles the consequences of.
                Section(
                    header: Text("Maintenance"),
                    footer: Text("Rarely needed. Migrate Episode Info runs once on a library that predates structured episodes. Match Again clears match status so videos are looked up afresh — it cannot be undone.")
                ) {
                    toolButton("Migrate Episode Info", icon: "arrow.triangle.branch",
                               action: onMigrateEpisodes)
                        .disabled(session.isFederated)
                    toolButton("Match Again", icon: "arrow.counterclockwise",
                               action: onResetMatches)
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
