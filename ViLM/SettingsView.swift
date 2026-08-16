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
    var onFindDuplicates: (() -> Void)?
    var onTagCleanup: (() -> Void)?
    var onClassifyTags: (() -> Void)?
    var onActorPhotoCleanup: (() -> Void)?
    var onPhotoTopUp: (() -> Void)?
    var onAliasSplits: (() -> Void)?
    var onRefreshMatched: (() -> Void)?
    var onIdentityGaps: (() -> Void)?
    /// The v28 identity upgrade gate. Read-only today.
    ///
    /// ⚠️ Declared beside `onIdentityGaps` deliberately — Swift requires
    /// arguments in declaration order, so a parameter's position here dictates
    /// where every call site must put it.
    var onIdentityUpgrade: (() -> Void)?
    var onTagCaseCleanup: (() -> Void)?
    var onReadFilenames: (() -> Void)?
    var onBatchMatchVideos: (() -> Void)?
    var onBatchMatchActors: (() -> Void)?
    var onBatchMatchStudios: (() -> Void)?
    var onStudioAudit: (() -> Void)?
    var onGraphAudit: (() -> Void)?
    /// #17 — what a rename would do, read before anything moves.
    var onRelocationPlan: (() -> Void)?
    var onMeasureVideos: (() -> Void)?
    /// What the tag vocabulary implies about itself.
    var onTagRelationships: (() -> Void)?
    /// When in a career each studio works.
    var onStudioSignatures: (() -> Void)?
    /// Performers connected by a studio but never by a video.
    var onTwoHop: (() -> Void)?

    /// Matches the source says are gone or moved. Beside the other audits, but
    /// its own tool: unlike them it OFFERS actions, and folding it into a
    /// screen that promises none would break that screen's own footer.
    var onStaleMatches: (() -> Void)?

    /// Fingerprint matches the source's own data does not strongly support.
    /// ⚠️ Beside Gone at the Source rather than in Fix Problems: both report
    /// evidence ABOUT the source's records, and neither repairs anything.
    var onDoubtfulMatches: (() -> Void)?

    /// Two profiles claiming one record at the source — the duplicate check
    /// that needs no heuristic, and the only one that can reach a profile with
    /// no name.
    var onSameIdentity: (() -> Void)?

    /// Titles that ended up in the series field, giving one video a series of
    /// its own. ⚠️ Leaves the operator's sequencing groups alone.
    var onSeriesTitles: (() -> Void)?
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

    /// 🚨 Hidden when the library is already upgraded, which both real
    /// libraries now are — the row reported "0 nodes re-keyed" and did nothing.
    ///
    /// ⚠️ Hidden rather than DELETED. Nothing in the app detects an
    /// un-upgraded library automatically, so removing the tool would leave a
    /// restored pre-v34 backup with no way to diagnose or repair it. A row that
    /// appears exactly when it has work is the version of "retire it" that does
    /// not throw away the recovery path.
    @State private var identityUpgradeRemaining = 0
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

                // ⚠️ Studio repairs are NOT listed here. `Studio Health` finds
                // them and routes to each one, which is where Repair Studio
                // Spelling has always lived — Fix Duplicate Studios was the odd
                // one out with a second, top-level entry that gave no
                // indication whether it had anything to do. Measured against
                // the real library it had none, while Studio Health reported
                // 180 findings across four other kinds.
                Section(
                    header: Text("Fix Problems"),
                    footer: Text("Each finds records that are wrong rather than merely incomplete, shows them, and changes nothing until you say so. Studio repairs are reached from Studio Health, which knows which of them have anything to do.")
                ) {
                    toolButton("Repair Tag Spelling", icon: "textformat.abc", action: onTagCaseCleanup)
                    // ⚠️ One library only, like the other profile-mutating
                    // tools. Attached, the audit reads the MAIN library alone —
                    // so a performer with twenty videos in the other library
                    // reads as having none, and "0 videos" is the strongest
                    // argument for merging a profile away. It would argue for
                    // deleting exactly the wrong half.
                    toolButton("Merge Duplicate Performers",
                               icon: "person.2.badge.gearshape", action: onAliasSplits)
                        .disabled(session.isFederated)
                    toolButton("Get More Photos",
                               icon: "photo.badge.plus", action: onPhotoTopUp)
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
                        ? "Find Duplicates scans every open library, so cross-library copies surface. The rest work on one at a time — detach to use them."
                        : "These report rather than change anything.")
                ) {
                    toolButton("Find Duplicate Videos",
                               icon: "square.on.square.dashed", action: onFindDuplicates)
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
                    toolButton("Missing Identities",
                               icon: "person.crop.circle.badge.questionmark",
                               action: onIdentityGaps)
                        .disabled(session.isFederated)
                    toolButton("Impossible Data",
                               icon: "exclamationmark.magnifyingglass", action: onGraphAudit)
                        .disabled(session.isFederated)
                    // ⚠️ Single-library, like Identity Upgrade. A path belongs
                    // to the library that holds it, and planning a rename
                    // across an attached pair would propose moving files
                    // between two catalogues that each think they own them.
                    toolButton("Relocation Plan",
                               icon: "folder.badge.gearshape", action: onRelocationPlan)
                        .disabled(session.isFederated)
                    // Reads only what previous fetches recorded — no network,
                    // so it opens instantly and works offline.
                    toolButton("Gone at the Source",
                               icon: "questionmark.folder", action: onStaleMatches)
                        .disabled(session.isFederated)
                    toolButton("Doubtful Matches",
                               icon: "questionmark.circle", action: onDoubtfulMatches)
                        .disabled(session.isFederated)
                    toolButton("Same Person, Twice",
                               icon: "person.2.crop.square.stack", action: onSameIdentity)
                        .disabled(session.isFederated)
                    toolButton("Titles in the Series Field",
                               icon: "textformat.abc.dottedunderline", action: onSeriesTitles)
                        .disabled(session.isFederated)
                }

                // ⭐ Not "Find Problems". Nothing in here is wrong — these
                // answer questions about the library that no single record can,
                // and filing them beside the repair tools would teach the
                // operator to read every finding as a defect.
                Section(
                    header: Text("Explore the Graph"),
                    footer: Text("Questions no single record can answer, worked out by joining several. They describe your library rather than correcting it, and change nothing.")
                ) {
                    toolButton("Tag Relationships",
                               icon: "tag.circle", action: onTagRelationships)
                        .disabled(session.isFederated)
                    toolButton("Studio Signatures",
                               icon: "chart.xyaxis.line", action: onStudioSignatures)
                        .disabled(session.isFederated)
                    toolButton("Never Worked Together",
                               icon: "arrow.triangle.branch", action: onTwoHop)
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
                    footer: Text("Rarely needed. Match Again clears match status so videos are looked up afresh — it cannot be undone. Measure Videos opens every file that has not been measured, so it takes a while.")
                ) {
                    toolButton("Match Again", icon: "arrow.counterclockwise",
                               action: onResetMatches)
                        .disabled(session.isFederated)
                    // ⚠️ Single-library. Identity is per database — a uid
                    // minted in one library means nothing in another — so this
                    // must never run across an attached pair.
                    if identityUpgradeRemaining > 0 {
                        toolButton("Identity Upgrade (\(identityUpgradeRemaining))",
                                   icon: "key", action: onIdentityUpgrade)
                            .disabled(session.isFederated)
                    }
                    // F6 (#10). ⚠️ Presented by ContentView like every other
                    // tool here, NOT from a sheet owned by this view. A first
                    // attempt held the sheet locally and it flashed and closed
                    // immediately: `toolButton` dismisses Settings and THEN
                    // runs the action, so a sheet presented from this view dies
                    // with its parent. The contract is documented on
                    // `toolButton` itself.
                    toolButton("Measure Videos", icon: "ruler",
                               action: onMeasureVideos)
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
            .task { await checkIdentityUpgrade() }
            .sheet(isPresented: $isShowingHelp) {
                HelpView(initialTopicID: HelpContent.settings.id)
            }

        }
        .macFormSheet()
    }

    // Every tool row behaves the same way: close Settings, then hand off to
    // the callback ContentView wired up (which presents the tool's sheet).
    /// ⭐ Off the main actor and best-effort. A count that cannot be taken
    /// leaves the row hidden, which is the same as the answer for every library
    /// that is already upgraded — and a Settings screen must not fail to open
    /// because a maintenance tool could not decide whether to appear.
    private func checkIdentityUpgrade() async {
        guard let libraryURL else { return }
        identityUpgradeRemaining = await Task.detached(priority: .utility) {
            guard let store = try? LibraryStore(at: libraryURL) else { return 0 }
            return (try? store.identityUpgradeRemaining()) ?? 0
        }.value
    }

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
