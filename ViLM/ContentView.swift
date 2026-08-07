// ContentView.swift
// The app's root view: owns the library lifecycle (security scope, bookmark,
// scan), the shared asset/profile caches every screen reads, the
// compact-vs-split navigation architecture, all feature sheets, Settings
// deep-link sequencing, and the global error toast.

import SwiftUI
import LibraryCore
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

// The sidebar's selection vocabulary — fixed sections plus dynamic
// actor/tag/studio/series/smart-collection entries. Top-level because
// nearly every screen filters or navigates by it.
enum SidebarItem: Hashable {
    case dashboard
    case allAssets
    case actorGallery
    case tagGallery
    case seriesGallery
    case studioGallery
    case actor(String)
    case tag(String)
    case studio(String)
    /// A studio and every imprint beneath it.
    ///
    /// ⚠️ A separate case rather than making `.studio` family-aware. Sidebar
    /// selections combine with `allSatisfy` — they AND — so the obvious
    /// approach of inserting each descendant as its own `.studio` item asks for
    /// videos belonging to EVERY studio in the family at once, which is zero.
    /// Making `.studio` itself family-aware would silently change what every
    /// existing studio page shows and what every saved filter means, and would
    /// remove the ability to ask the narrower question at all.
    case studioFamily(String)
    case series(String)
    case smartCollection(String, String) // id, name
}

struct ContentView: View {
    @State private var assets: [Asset] = []
    // Shared across Dashboard, Actor Gallery, Tag Gallery, All Assets, and
    // Sidebar so each doesn't independently re-fetch every entity profile and
    // re-list the profile photos directory on every appearance. Reloaded via
    // loadEntityProfiles(from:) whenever "ReloadAssets" fires — that
    // notification is this app's general "library data changed" signal, not
    // just for assets.
    @State private var entityProfiles: [String: EntityProfile] = [:]
    @State private var profileImageFileNames: Set<String> = []
    @State private var akaMap: [String: String] = [:]
    @State private var selectedLibraryURL: URL?
    @State private var selectedAssetIDs: Set<Asset.ID> = []
    @State private var sidebarSelection: Set<SidebarItem> = [.allAssets]
    @State private var searchText = ""
    @State private var gridRefreshID = UUID()
    @State private var missingAssetIDs: Set<Asset.ID> = []
    @State private var filteredAssetContext: [Asset.ID] = []
    @State private var smartCollections: [SmartCollection] = []
    // Playlists (hand-picked ordered lists) live in the PRIMARY library, like
    // Smart Collections. Items are the ordered assetId strings per playlist.
    @State private var playlists: [Playlist] = []
    @State private var playlistItemsByID: [String: [String]] = [:]
    @State private var isShowingActorSync = false

    @State private var pendingAssetFilter: AssetFilterCriteria?
    @State private var pendingAssetSort: AssetsGridView.SortOption?
    @State private var pendingAssetSortAscending: Bool?

    @State private var pendingActorFilter: ActorFilterCriteria?
    @State private var pendingActorSort: ActorFilterCriteria.SortOption?
    @State private var pendingActorSortAscending: Bool?

    // A direct-play quick action stashes its picked video here; Video Details
    // consumes it on appear to auto-start playback.
    @State private var pendingAutoPlayAssetID: UUID?
    // Home Screen quick actions arrive here (from the scene delegate).
    @ObservedObject private var quickActionRouter = QuickActionRouter.shared

    @AppStorage("defaultHomePage") private var defaultHomePage: String = "dashboard"
    @State private var isShowingSettings = false

    // Transient error banner fed by AppErrorReporter (see AppComponents).
    @State private var errorToastMessage: String?
    @State private var errorToastDismissTask: Task<Void, Never>?

    // Navigation queued by a Settings deep-link, run in the sheet's
    // onDismiss once the dismissal has actually completed.
    @State private var pendingSettingsDeepLink: (() -> Void)?
    @State private var hasInitializedSelection = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var detailPath: [AppRoute] = []

    // Feature Sheets
    @State private var isShowingFileNameAudit = false
    @State private var isShowingTagCleanup = false
    @State private var isShowingTagClassification = false
    @State private var isShowingActorPhotoCleanup = false
    @State private var isShowingAliasSplits = false
    @State private var isShowingVideoRefresh = false
    @State private var isShowingTagCaseCleanup = false
    @State private var isShowingReadFilenames = false
    @State private var isShowingBatchMatch = false
    @State private var isShowingActorBatchMatch = false
    @State private var isShowingStudioConflicts = false
    @State private var isShowingStudioBatchMatch = false
    @State private var isShowingStudioSpelling = false
    @State private var isShowingStudioAudit = false
    @State private var isShowingGraphAudit = false
    /// The video an audit finding asked to open, run once its sheet has closed.
    @State private var pendingAuditVideo: (() -> Void)?
    /// The repair a studio finding asked for, run once the audit sheet has
    /// actually closed. Presenting a sheet while another is dismissing is how
    /// the second one silently fails to appear.
    @State private var pendingStudioFix: (() -> Void)?
    @State private var isShowingGraphConnect = false
    @State private var isShowingMatchReset = false
    @State private var isShowingDuplicateDetection = false
    @State private var isShowingEpisodeBackfill = false
    @State private var isShowingActorLibraryExport = false
    @State private var isShowingActorLibraryImport = false
    @State private var isShowingLibraryTransfer = false
    @State private var isShowingLibraryBackup = false

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isShowingLibraryPicker = false
    // Single navigation path for compact-width (iPhone) layout
    @State private var navigationPath: [AppRoute] = []
#endif

    // Security-scoped access to the active library folder, held open for
    // the whole session (see beginSecurityScope).
    @State private var activeSecurityScopedURL: URL?
    @State private var hasActiveSecurityScope: Bool = false

    private let bookmarkKey = "libraryBookmark"

    var body: some View {
        rootNavigationView
            .overlay(alignment: .bottom) {
                if let message = errorToastMessage {
                    errorToast(message)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AppErrorReporter.notificationName)) { note in
                if let message = note.object as? String {
                    showErrorToast(message)
                }
            }
            .onChange(of: sidebarSelection) { _, _ in
                detailPath.removeAll()
            }
            .onChange(of: selectedAssetIDs) { _, _ in
                detailPath.removeAll()
            }
            .onChange(of: selectedLibraryURL) { _, newURL in
                // One-time cleanup of the orphaned face-recognition cache left
                // by the removed "Suggest Actors" feature — harmless dead data,
                // deleted the first time a library that still has it is opened.
                guard let url = newURL else { return }
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(
                        at: url.appendingPathComponent(".catalog/facePrints", isDirectory: true))
                }
            }
            // Perform a pending Home Screen quick action once the library is
            // loaded — the pending value or the just-loaded assets can arrive
            // in either order (cold vs. warm launch).
            .onChange(of: quickActionRouter.pending) { _, _ in
                performPendingQuickActionIfReady()
            }
            .onChange(of: assets.count) { _, _ in
                performPendingQuickActionIfReady()
            }
#if os(iOS)
            .onChange(of: horizontalSizeClass) { _, newValue in
                syncNavigation(for: newValue)
            }
#endif
            .onAppear {
                loadLastLibrary()
                if !hasInitializedSelection {
                    switch defaultHomePage {
                    case "allAssets": sidebarSelection = [.allAssets]
                    case "actorGallery": sidebarSelection = [.actorGallery]
                    case "tagGallery": sidebarSelection = [.tagGallery]
                    default: sidebarSelection = [.dashboard]
                    }
                    hasInitializedSelection = true
                }
                if let url = selectedLibraryURL {
                    loadSmartCollections(from: url)
                }
            }
            .onDisappear { endSecurityScope() }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleFullScreen"))) { _ in
                if columnVisibility == .detailOnly {
                    columnVisibility = .all
                } else {
                    columnVisibility = .detailOnly
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
                isShowingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReloadSmartCollections"))) { _ in
                if let url = selectedLibraryURL {
                    loadSmartCollections(from: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DeleteSmartCollection"))) { notification in
                if let id = notification.object as? String, let url = selectedLibraryURL {
                    do {
                        let store = try LibraryStore(at: url)
                        try store.deleteSmartCollection(id: id)
                        loadSmartCollections(from: url)
                    } catch {
                        print("Failed to delete smart collection: \(error)")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReloadAssets"))) { _ in
                if let url = selectedLibraryURL {
                    loadEntityProfiles(from: url)
                    reloadUnionAssets()
                    loadPlaylists()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReloadPlaylists"))) { _ in
                loadPlaylists()
            }
            .sheet(isPresented: $isShowingActorSync) {
                ActorSyncView()
            }
            .onChange(of: selectedLibraryURL) { _, _ in
                loadPlaylists()
            }
            .sheet(isPresented: $isShowingSettings, onDismiss: {
                pendingSettingsDeepLink?()
                pendingSettingsDeepLink = nil
            }) {
                SettingsView(
                    libraryURL: selectedLibraryURL,
                    onOpenLibrary: openLibrary,
                    onCheckForChanges: validateLibrary,
                    onAuditFileName: { isShowingFileNameAudit = true },
                    onFindDuplicates: { isShowingDuplicateDetection = true },
                    onMigrateEpisodes: { isShowingEpisodeBackfill = true },
                    onTagCleanup: { isShowingTagCleanup = true },
                    onClassifyTags: { isShowingTagClassification = true },
                    onActorPhotoCleanup: { isShowingActorPhotoCleanup = true },
                    onAliasSplits: { isShowingAliasSplits = true },
                    onRefreshMatched: { isShowingVideoRefresh = true },
                    onTagCaseCleanup: { isShowingTagCaseCleanup = true },
                    onReadFilenames: { isShowingReadFilenames = true },
                    onBatchMatchVideos: { isShowingBatchMatch = true },
                    onBatchMatchActors: { isShowingActorBatchMatch = true },
                    onBatchMatchStudios: { isShowingStudioBatchMatch = true },
                    onStudioConflicts: { isShowingStudioConflicts = true },
                    onStudioAudit: { isShowingStudioAudit = true },
                    onGraphAudit: { isShowingGraphAudit = true },
                    onConnectGraph: { isShowingGraphConnect = true },
                    onResetMatches: { isShowingMatchReset = true },
                    onMoveVideos: { isShowingLibraryTransfer = true },
                    onBackupRestore: { isShowingLibraryBackup = true },
                    onExportActorLibrary: { isShowingActorLibraryExport = true },
                    onImportActorLibrary: { isShowingActorLibraryImport = true },
                    onSelectAsset: settingsDidSelectAsset,
                    onSelectActor: settingsDidSelectActor,
                    onSelectTag: settingsDidSelectTag,
                    onOpenTagGallery: settingsDidOpenTagGallery
                )
            }
            .sheet(isPresented: $isShowingFileNameAudit) {
                if let url = selectedLibraryURL {
                    FileNameAuditView(
                        libraryURL: url,
                        assets: assets,
                        onRefresh: { reloadUnionAssets() }
                    )
                }
            }
            .sheet(isPresented: $isShowingDuplicateDetection) {
                if let url = selectedLibraryURL {
                    DuplicateDetectionView(
                        libraryURL: url,
                        assets: assets,
                        onRefresh: { reloadUnionAssets() }
                    )
                }
            }
            .sheet(isPresented: $isShowingEpisodeBackfill) {
                if let url = selectedLibraryURL {
                    EpisodeBackfillView(libraryURL: url, assets: assets)
                }
            }
            .sheet(isPresented: $isShowingActorLibraryExport) {
                if let url = selectedLibraryURL {
                    ActorLibraryExportView(libraryURL: url)
                }
            }
            .sheet(isPresented: $isShowingActorLibraryImport) {
                if let url = selectedLibraryURL {
                    ActorLibraryImportView(libraryURL: url, onRefresh: {
                        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
                    })
                }
            }
            .sheet(isPresented: $isShowingLibraryTransfer) {
                if let url = selectedLibraryURL {
                    LibraryTransferView(openLibraryURL: url, onRefresh: {
                        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
                    })
                }
            }
            .sheet(isPresented: $isShowingLibraryBackup) {
                if let url = selectedLibraryURL {
                    LibraryBackupView(openLibraryURL: url, onRestored: { restoredURL in
                        // Open the restored folder as the active library, which
                        // scans it (Check for Changes) and flags any missing files.
                        processFolder(at: restoredURL)
                    })
                }
            }
            .sheet(isPresented: $isShowingActorBatchMatch) {
                let urls = LibrarySession.shared.allURLs
                if !urls.isEmpty {
                    ActorBatchMatchView(libraryURLs: urls) { reloadUnionAssets() }
                }
            }
            .sheet(isPresented: $isShowingMatchReset) {
                if let url = selectedLibraryURL {
                    MatchResetView(libraryURL: url) { reloadUnionAssets() }
                }
            }
            .sheet(isPresented: $isShowingGraphConnect, onDismiss: {
                pendingAuditVideo?()
                pendingAuditVideo = nil
            }) {
                if let url = selectedLibraryURL {
                    GraphConnectView(libraryURL: url,
                                     onFinish: { reloadUnionAssets() },
                                     onExplore: { item in
                                        // Stored, not run: this sheet is still
                                        // on screen. `onDismiss` runs it.
                                        pendingAuditVideo = { openSidebarItem(item) }
                                     })
                }
            }
            .sheet(isPresented: $isShowingStudioConflicts) {
                let urls = LibrarySession.shared.allURLs
                if !urls.isEmpty {
                    StudioConflictCleanupView(libraryURLs: urls) { reloadUnionAssets() }
                }
            }
            .sheet(isPresented: $isShowingStudioSpelling) {
                if let url = selectedLibraryURL {
                    StudioSpellingCleanupView(libraryURL: url, assets: assets) {
                        reloadUnionAssets()
                    }
                }
            }
            .sheet(isPresented: $isShowingStudioBatchMatch) {
                let urls = LibrarySession.shared.allURLs
                if !urls.isEmpty {
                    StudioBatchMatchView(libraryURLs: urls) { reloadUnionAssets() }
                }
            }
            .sheet(isPresented: $isShowingGraphAudit, onDismiss: {
                pendingAuditVideo?()
                pendingAuditVideo = nil
            }) {
                if let url = selectedLibraryURL {
                    GraphAuditView(libraryURL: url) { assetID in
                        // Stored, not run: this sheet is still on screen, and
                        // navigating behind it would be invisible until it
                        // closed. `onDismiss` runs it.
                        //
                        // ⚠️ Goes through `openAsset`, the same path Settings
                        // uses. Setting `selectedAssetIDs` by hand here was the
                        // bug — correct on a Mac, a no-op on a phone.
                        pendingAuditVideo = { openAsset(assetID) }
                    }
                }
            }
            .sheet(isPresented: $isShowingStudioAudit, onDismiss: {
                pendingStudioFix?()
                pendingStudioFix = nil
            }) {
                if let url = selectedLibraryURL {
                    StudioAuditView(libraryURL: url, onFix: studioAuditDidRequestFix)
                }
            }
            .sheet(isPresented: $isShowingBatchMatch) {
                let urls = LibrarySession.shared.allURLs
                if !urls.isEmpty {
                    VideoBatchMatchView(libraryURLs: urls) { reloadUnionAssets() }
                }
            }
            .sheet(isPresented: $isShowingReadFilenames) {
                // Every open library, matching the rename paths. Reading only
                // the primary left an attached library untouched and narrowed
                // the vocabulary the parse works from.
                let urls = LibrarySession.shared.allURLs
                if !urls.isEmpty {
                    FileNameParseReviewView(libraryURLs: urls) { reloadUnionAssets() }
                }
            }
            .sheet(isPresented: $isShowingTagCaseCleanup) {
                if let url = selectedLibraryURL {
                    TagCaseCleanupView(libraryURL: url) {
                        reloadUnionAssets()
                    }
                }
            }
            .sheet(isPresented: $isShowingVideoRefresh) {
                VideoRefreshView(libraryURLs: LibrarySession.shared.allURLs) {
                    reloadUnionAssets()
                }
            }
            .sheet(isPresented: $isShowingAliasSplits) {
                if let url = selectedLibraryURL {
                    AliasSplitMergeView(libraryURL: url) {
                        loadEntityProfiles(from: url)
                        reloadUnionAssets()
                    }
                }
            }
            .sheet(isPresented: $isShowingActorPhotoCleanup) {
                if let url = selectedLibraryURL {
                    ActorPhotoCleanupView(libraryURL: url) {
                        loadEntityProfiles(from: url)
                    }
                }
            }
            .sheet(isPresented: $isShowingTagClassification) {
                if let url = selectedLibraryURL {
                    TagClassificationView(
                        libraryURL: url,
                        assets: assets,
                        onRefresh: {
                            reloadUnionAssets()
                            loadEntityProfiles(from: url)
                        }
                    )
                }
            }
            .sheet(isPresented: $isShowingTagCleanup) {
                if let url = selectedLibraryURL {
                    TagCleanupView(
                        libraryURL: url,
                        assets: assets,
                        onRefresh: {
                            reloadUnionAssets()
                            loadEntityProfiles(from: url)
                        }
                    )
                }
            }
#if os(iOS)
            .sheet(isPresented: $isShowingLibraryPicker) {
                LibraryFolderPicker { pickedURL in
                    guard let pickedURL else { return }
                    processFolder(at: pickedURL)
                }
            }
#endif
    }

    // MARK: - Navigation Layout

    @ViewBuilder
    private var rootNavigationView: some View {
#if os(iOS)
        // Compact width (iPhone, narrow iPad windows): a single NavigationStack.
        // Regular width (iPad full screen, landscape big phones): the split view.
        // Both are driven by the same state, so rotating preserves context.
        if horizontalSizeClass == .compact {
            compactNavigationView
        } else {
            splitNavigationView
        }
#else
        splitNavigationView
#endif
    }

#if os(iOS)
    private var compactNavigationView: some View {
        NavigationStack(path: $navigationPath) {
            SidebarView(
                selection: $sidebarSelection,
                assets: assets,
                libraryURL: selectedLibraryURL,
                entityProfiles: entityProfiles,
                onApplyFilters: {
                    if navigationPath.isEmpty {
                        navigationPath.append(.browse)
                    }
                },
                onAttachLibrary: { attachLibrary(at: $0) },
                onDetachLibrary: { detachLibrary(at: $0) },
                onSyncActors: { isShowingActorSync = true }
            )
            .navigationDestination(for: AppRoute.self) { route in
                destinationView(for: route)
            }
        }
        .environment(\.usesStackNavigation, true)
    }

    // Rebuild the compact path (or clear it) when the layout mode flips,
    // so rotation lands the user on the same content instead of dumping
    // them back at the sidebar.
    private func syncNavigation(for sizeClass: UserInterfaceSizeClass?) {
        if sizeClass == .compact {
            if selectedAssetIDs.count == 1, let id = selectedAssetIDs.first {
                navigationPath = [.browse, .asset(id, context: filteredAssetContext)]
            } else if let actor = selectedSidebarActors.first {
                navigationPath = [.browse, .entityProfile(category: "actor", name: actor)]
            } else {
                navigationPath = [.browse]
            }
        } else {
            navigationPath.removeAll()
        }
    }
#endif

    private var splitNavigationView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: $sidebarSelection,
                assets: assets,
                libraryURL: selectedLibraryURL,
                entityProfiles: entityProfiles,
                onApplyFilters: {},
                onAttachLibrary: { attachLibrary(at: $0) },
                onDetachLibrary: { detachLibrary(at: $0) },
                onSyncActors: { isShowingActorSync = true }
            )
        } content: {
#if os(iOS)
            NavigationStack {
                browseContentView
                    .navigationDestination(for: AppRoute.self) { route in
                        destinationView(for: route)
                    }
            }
#else
            browseContentView
#endif
        } detail: {
            NavigationStack(path: $detailPath) {
                detailRootView
                    .navigationDestination(for: AppRoute.self) { route in
                        destinationView(for: route)
                    }
            }
        }
    }

    @ViewBuilder
    private var browseContentView: some View {
        if sidebarSelection.contains(.dashboard) {
            DashboardView(
                assets: assets,
                sidebarSelection: $sidebarSelection,
                selectedAssetIDs: $selectedAssetIDs,
                libraryURL: selectedLibraryURL,
                entityProfiles: entityProfiles,
                profileImageFileNames: profileImageFileNames,
                akaMap: akaMap,
                pendingAssetFilter: $pendingAssetFilter,
                pendingAssetSort: $pendingAssetSort,
                pendingAssetSortAscending: $pendingAssetSortAscending,
                pendingActorFilter: $pendingActorFilter,
                onSeeAllShelf: showShelf,
                onQuickAction: performQuickAction,
                smartCollections: smartCollections,
                playlists: playlists,
                playlistItems: playlistItemsByID,
                onOpenPlaylist: openPlaylist
            )
        } else if sidebarSelection.contains(.actorGallery) {
            ActorGridView(
                assets: assets,
                sidebarSelection: $sidebarSelection,
                selectedAssetIDs: $selectedAssetIDs,
                libraryURL: selectedLibraryURL,
                pendingFilter: $pendingActorFilter,
                pendingSort: $pendingActorSort,
                pendingSortAscending: $pendingActorSortAscending,
                entityProfiles: entityProfiles,
                profileImageFileNames: profileImageFileNames,
                akaMap: akaMap,
                onPullToRefresh: refreshLibrary
            )
        } else if sidebarSelection.contains(.tagGallery) {
            TagGalleryView(
                assets: assets,
                sidebarSelection: $sidebarSelection,
                libraryURL: selectedLibraryURL,
                entityProfiles: entityProfiles,
                onPullToRefresh: refreshLibrary
            )
        } else if sidebarSelection.contains(.seriesGallery) {
            SeriesGalleryView(
                assets: assets,
                sidebarSelection: $sidebarSelection,
                libraryURL: selectedLibraryURL,
                onPullToRefresh: refreshLibrary
            )
        } else if sidebarSelection.contains(.studioGallery) {
            StudioGalleryView(
                assets: assets,
                sidebarSelection: $sidebarSelection,
                libraryURL: selectedLibraryURL,
                entityProfiles: entityProfiles,
                onPullToRefresh: refreshLibrary
            )
        } else {
            AssetsGridView(
                assets: assets,
                sidebarSelection: $sidebarSelection,
                searchText: $searchText,
                selectedAssetIDs: $selectedAssetIDs,
                missingAssetIDs: missingAssetIDs,
                libraryURL: selectedLibraryURL,
                refreshID: gridRefreshID,
                filteredAssetContext: $filteredAssetContext,
                onPullToRefresh: refreshLibrary,
                entityProfiles: entityProfiles,
                akaMap: akaMap,
                pendingFilter: $pendingAssetFilter,
                pendingSort: $pendingAssetSort,
                pendingSortAscending: $pendingAssetSortAscending
            )
        }
    }

    private var selectedSidebarActors: [String] {
        sidebarSelection.compactMap { item -> String? in
            if case .actor(let a) = item { return a }
            return nil
        }
    }

    @ViewBuilder
    private var detailRootView: some View {
        let selectedActors = selectedSidebarActors
        ZStack {
            if !selectedAssetIDs.isEmpty {
                InspectorView(
                    sidebarSelection: $sidebarSelection,
                    selectedAssetIDs: selectedAssetIDs,
                    assets: $assets,
                    selectedAssetBinding: $selectedAssetIDs,
                    gridRefreshID: $gridRefreshID,
                    libraryURL: selectedLibraryURL,
                    missingAssetIDs: $missingAssetIDs,
                    contextAssetIDs: filteredAssetContext,
                    autoPlayAssetID: $pendingAutoPlayAssetID
                )
            } else if selectedActors.count == 1, let actor = selectedActors.first {
                // Same profile page the compact layout pushes (graph header +
                // filmography); its Edit button opens the editor as a sheet.
                EntityProfileRouteView(
                    category: "actor",
                    name: actor,
                    assets: assets,
                    libraryURL: selectedLibraryURL,
                    gridRefreshID: gridRefreshID,
                    entityProfiles: entityProfiles,
                    akaMap: akaMap
                )
                .id(actor)
            } else if selectedActors.count > 1 {
                ActorInspectorView(
                    selectedActors: selectedActors,
                    libraryURL: selectedLibraryURL,
                    gridRefreshID: $gridRefreshID
                )
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.right",
                    description: Text("Select a video or actor to see details")
                )
            }
        }
    }

    // MARK: - Error Toast

    private func errorToast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                errorToastDismissTask?.cancel()
                withAnimation(.easeOut(duration: 0.2)) { errorToastMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.4)))
        .frame(maxWidth: 500)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func showErrorToast(_ message: String) {
        errorToastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            errorToastMessage = message
        }
        errorToastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                errorToastMessage = nil
            }
        }
    }

    // MARK: - Settings Deep Links
    //
    // Extracted from the SettingsView(...) call site — inlining these as
    // closures there pushed the surrounding expression past the Swift
    // type-checker's time budget.
    //
    // Each handler stores its navigation as pending work and dismisses the
    // sheet; the sheet's onDismiss runs it once the dismissal has actually
    // finished. (This used to be a hardcoded 0.1s timer, which was a guess
    // about animation duration.)

    private func deferUntilSettingsDismissed(_ action: @escaping () -> Void) {
        pendingSettingsDeepLink = action
        isShowingSettings = false
    }

    /// Sends a studio finding to the tool that resolves it.
    ///
    /// Stored rather than run: the audit sheet is still on screen at this
    /// point, and opening the destination now would present a sheet on top of
    /// one that is closing — which does nothing at all. `onDismiss` runs it.
    ///
    private func studioAuditDidRequestFix(_ fix: StudioFix) {
        switch fix {
        case .matchStudios:
            pendingStudioFix = { isShowingStudioBatchMatch = true }
        case .fixDuplicateStudios:
            pendingStudioFix = { isShowingStudioConflicts = true }
        case .repairStudioSpelling:
            pendingStudioFix = { isShowingStudioSpelling = true }
        case .connectTheGraph:
            pendingStudioFix = { isShowingGraphConnect = true }
        case .matchAgain:
            pendingStudioFix = { isShowingMatchReset = true }
        case .removeOrphanedProfiles:
            pendingStudioFix = { isShowingTagCleanup = true }
        // Two findings have no repair tool. The audit says so on the row
        // rather than offering a button that goes nowhere.
        case .none:
            pendingStudioFix = nil
        }
    }

    // MARK: - Quick Actions

    private func performPendingQuickActionIfReady() {
        guard let action = quickActionRouter.pending else { return }
        // A tap that couldn't run promptly must not fire minutes later as a
        // surprise autoplay when a library finally loads (DEFECT_INVENTORY M6).
        if let since = quickActionRouter.pendingSince, Date().timeIntervalSince(since) > 60 {
            quickActionRouter.pending = nil
            return
        }
        // No library yet: keep waiting — a cold launch from a quick action
        // reaches here before loadLastLibrary() finishes.
        guard selectedLibraryURL != nil else { return }
        // Library open but EMPTY: the action can never become runnable here,
        // so consume it with feedback instead of leaving it pending.
        guard !assets.isEmpty else {
            quickActionRouter.pending = nil
            AppErrorReporter.report("Quick actions need videos in the library — this one is empty.")
            return
        }
        quickActionRouter.pending = nil
        performQuickAction(action)
    }

    // Runs a quick action now (used by both the Home Screen shortcut and the
    // in-app Dashboard shuffle menu). Re-rolls its pick every invocation.
    func performQuickAction(_ action: QuickAction) {
        guard selectedLibraryURL != nil, !assets.isEmpty else {
            AppErrorReporter.report("Open a library first to use quick actions.")
            return
        }
        var rng = SystemRandomNumberGenerator()
        let result = QuickActionPicker().pick(
            action, assets: assets, entityProfiles: entityProfiles, akaMap: akaMap, using: &rng)

        switch result {
        case .openFilteredList(let criteria):
            pendingAssetFilter = criteria
            sidebarSelection = [.allAssets]
#if os(iOS)
            if horizontalSizeClass == .compact { navigationPath = [.browse]; return }
#endif
            columnVisibility = .all
        case .play(let asset):
            selectedAssetIDs = [asset.id]
            pendingAutoPlayAssetID = asset.id
#if os(iOS)
            if horizontalSizeClass == .compact {
                navigationPath = [.browse, .asset(asset.id, context: [asset.id])]
                return
            }
#endif
            // Split view: the detail column's root shows the selected asset.
            columnVisibility = .all
        case .nothingAvailable:
            AppErrorReporter.report("Nothing to play yet.")
        }
    }

    /// Loads playlists (and their ordered members) from the primary library.
    private func loadPlaylists() {
        guard let url = selectedLibraryURL else {
            playlists = []
            playlistItemsByID = [:]
            return
        }
        do {
            let store = try LibraryStore(at: url)
            let lists = try store.fetchAllPlaylists()
            var itemsByID: [String: [String]] = [:]
            for list in lists {
                itemsByID[list.id] = try store.fetchPlaylistItems(playlistId: list.id).map(\.assetId)
            }
            playlists = lists
            playlistItemsByID = itemsByID
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }

    /// Opens a playlist's detail page (Dashboard "See All", like shelves).
    private func openPlaylist(_ id: String) {
#if os(iOS)
        if horizontalSizeClass == .compact {
            navigationPath.append(.playlist(id))
            return
        }
#endif
        detailPath.append(.playlist(id))
    }

    /// Plays a video from a playlist (row Play / Shuffle): same auto-play
    /// mechanism as the quick actions.
    private func playFromPlaylist(_ assetID: Asset.ID) {
        selectedAssetIDs = [assetID]
        pendingAutoPlayAssetID = assetID
#if os(iOS)
        if horizontalSizeClass == .compact {
            navigationPath.append(.asset(assetID, context: [assetID]))
            return
        }
#endif
        detailPath.append(.asset(assetID, context: [assetID]))
    }

    // A Smart Shelf "See All" opens its full live list as a pushed route —
    // onto the compact stack on iPhone, or the detail stack on iPad/macOS.
    private func showShelf(_ query: LibraryQuery) {
#if os(iOS)
        if horizontalSizeClass == .compact {
            navigationPath.append(.shelf(query))
            return
        }
#endif
        detailPath.append(.shelf(query))
    }

    private func settingsDidSelectAsset(_ assetID: Asset.ID) {
        deferUntilSettingsDismissed { openAsset(assetID) }
    }

    /// Shows the library filtered to one entity, from wherever the operator was.
    ///
    /// ⚠️ Compact layout navigates by `navigationPath`, so setting the sidebar
    /// alone would be a no-op on a phone — the same mistake the Impossible Data
    /// rows made. Both paths, in one place.
    private func openSidebarItem(_ item: SidebarItem) {
        selectedAssetIDs = []
        sidebarSelection = [item]
#if os(iOS)
        if horizontalSizeClass == .compact {
            switch item {
            case .actor(let name):
                navigationPath = [.browse, .entityProfile(category: "actor", name: name)]
            case .tag(let name):
                navigationPath = [.browse, .entityProfile(category: "tag", name: name)]
            case .studio(let name):
                navigationPath = [.browse, .entityProfile(category: "studio", name: name)]
            default:
                navigationPath = [.browse]
            }
            return
        }
#endif
        columnVisibility = .all
    }

    /// Shows one video, from wherever the operator was.
    ///
    /// ⚠️ Extracted 2026-08-06 because it was reimplemented by hand for the
    /// Impossible Data report and got it wrong. On a phone `selectedAssetIDs`
    /// alone changes NOTHING visible — compact layout navigates by
    /// `navigationPath` — so the report's rows did nothing at all when tapped.
    ///
    /// One implementation, so the next caller cannot repeat that.
    private func openAsset(_ assetID: Asset.ID) {
#if os(iOS)
        if horizontalSizeClass == .compact {
            sidebarSelection = [.allAssets]
            selectedAssetIDs = [assetID]
            navigationPath = [.browse, .asset(assetID, context: filteredAssetContext)]
            return
        }
#endif
        // Also resets the sidebar: a gallery selection would otherwise keep the
        // detail column on the gallery rather than the video.
        sidebarSelection = [.allAssets]
        selectedAssetIDs = [assetID]
        columnVisibility = .all
    }

    private func settingsDidSelectActor(_ actorID: String) {
        deferUntilSettingsDismissed {
#if os(iOS)
            if horizontalSizeClass == .compact {
                sidebarSelection = [.actorGallery]
                selectedAssetIDs.removeAll()
                navigationPath = [.browse, .entityProfile(category: "actor", name: actorID)]
                return
            }
#endif
            selectedAssetIDs.removeAll()
            sidebarSelection = [.actor(actorID)]
            columnVisibility = .all
        }
    }

    private func settingsDidSelectTag(_ tagName: String) {
        deferUntilSettingsDismissed {
#if os(iOS)
            if horizontalSizeClass == .compact {
                sidebarSelection = [.tag(tagName)]
                selectedAssetIDs.removeAll()
                navigationPath = [.browse]
                return
            }
#endif
            selectedAssetIDs.removeAll()
            sidebarSelection = [.tag(tagName)]
            columnVisibility = .all
        }
    }

    private func settingsDidOpenTagGallery() {
        deferUntilSettingsDismissed {
#if os(iOS)
            if horizontalSizeClass == .compact {
                sidebarSelection = [.tagGallery]
                selectedAssetIDs.removeAll()
                navigationPath = [.browse]
                return
            }
#endif
            selectedAssetIDs.removeAll()
            sidebarSelection = [.tagGallery]
            columnVisibility = .all
        }
    }

    // MARK: - Library Logic

    func openLibrary() {
#if os(macOS)
        openLibrary_macOS()
#else
        isShowingLibraryPicker = true
#endif
    }

#if os(macOS)
    private func openLibrary_macOS() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select Library"

        if panel.runModal() == .OK, let url = panel.url {
            processFolder(at: url)
        }
    }
#endif

    // MARK: - Validation Logic

    private func validateLibrary() {
        Task { await refreshLibrary() }
    }

    // Same "Check for Changes" work as validateLibrary(), exposed as an
    // awaitable so pull-to-refresh on the grids can hold their spinner until
    // it actually finishes, instead of firing and forgetting.
    private func refreshLibrary() async {
        guard let primary = selectedLibraryURL else { return }
        // Check for Changes covers EVERY open library — each scanned within
        // its own scope claim so a mid-refresh detach can't cut off file
        // access. Missing-file validation accumulates across all of them.
        let openURLs = LibrarySession.shared.allURLs
        var missing: Set<Asset.ID> = []
        for url in openURLs {
            do {
                try await ScopedOperation.run(holding: [url]) {
                    let store = try LibraryStore(at: url)

                    // 1. Check for new files
                    try await LibraryScanner(store: store).scan(at: url)

                    // 2. Generate thumbnails for any missing ones + validate files
                    let rows = try store.fetchAllAssets()
                    let service = ContactSheetService(store: store)
                    for asset in rows {
                        try? await service.generateContactSheet(for: asset, libraryURL: url)
                        try? await service.generateSingleThumbnail(for: asset, libraryURL: url)
                        if !FileManager.default.fileExists(atPath: url.appendingPathComponent(asset.relativePath).path) {
                            missing.insert(asset.id)
                        }
                    }
                }
            } catch {
                print("Check for Changes failed for \(url.lastPathComponent): \(error)")
                AppErrorReporter.report("Check for Changes problem in “\((url.path as NSString).abbreviatingWithTildeInPath)”: \(error.localizedDescription)")
            }
        }

        // 3. Refresh the union + profiles and update UI.
        let finalMissing = missing
        await MainActor.run {
            reloadUnionAssets(refreshGrid: false)
            loadEntityProfiles(from: primary)
            self.missingAssetIDs = finalMissing
            self.gridRefreshID = UUID()
        }
    }

    // MARK: - Route Destinations

    @ViewBuilder
    private func destinationView(for route: AppRoute) -> some View {
        switch route {
        case .browse:
            browseContentView
        case .shelf(let query):
            ShelfDetailView(
                query: query,
                assets: assets,
                libraryURL: selectedLibraryURL,
                selectedAssetIDs: $selectedAssetIDs
            )
        case .playlist(let id):
            PlaylistDetailView(
                playlistID: id,
                assets: assets,
                onPlay: playFromPlaylist
            )
        case .asset(let id, let context):
            InspectorView(
                sidebarSelection: $sidebarSelection,
                selectedAssetIDs: selectedAssetIDs.isEmpty ? [id] : selectedAssetIDs,
                assets: $assets,
                selectedAssetBinding: $selectedAssetIDs,
                gridRefreshID: $gridRefreshID,
                libraryURL: selectedLibraryURL,
                missingAssetIDs: $missingAssetIDs,
                contextAssetIDs: context,
                autoPlayAssetID: $pendingAutoPlayAssetID
            )
            .onAppear {
                if !selectedAssetIDs.contains(id) {
                    selectedAssetIDs = [id]
                }
            }
        case .assets(let ids):
            InspectorView(
                sidebarSelection: $sidebarSelection,
                selectedAssetIDs: ids,
                assets: $assets,
                selectedAssetBinding: $selectedAssetIDs,
                gridRefreshID: $gridRefreshID,
                libraryURL: selectedLibraryURL,
                missingAssetIDs: $missingAssetIDs
            )
        case .entityProfile(let category, let name):
            EntityProfileRouteView(
                category: category,
                name: name,
                assets: assets,
                libraryURL: selectedLibraryURL,
                gridRefreshID: gridRefreshID,
                entityProfiles: entityProfiles,
                akaMap: akaMap
            )
        case .batchActors(let ids):
            BatchEntityProfileEditorView(
                libraryURL: selectedLibraryURL,
                entityIds: ids.map { "actor:\($0)" },
                onSave: { _ in
                    gridRefreshID = UUID()
                    if let url = selectedLibraryURL { loadEntityProfiles(from: url) }
                }
            )
        }
    }

    // Keeps security-scoped access open as long as this library is selected.
    private func beginSecurityScope(for url: URL) {
        // Every library-open path funnels through here, making it the one
        // reliable point to keep the session resolver's primary in sync.
        LibrarySession.shared.setPrimary(url)
        // Stop previous if different
        if let current = activeSecurityScopedURL, current != url, hasActiveSecurityScope {
            current.stopAccessingSecurityScopedResource()
            hasActiveSecurityScope = false
            activeSecurityScopedURL = nil
            // Also drop the old library's cached SQLite connection —
            // otherwise every library visited this session keeps an open
            // connection (and WAL file handles) alive for the app's lifetime.
            LibraryStore.evictCachedConnections(keepingLibraryAt: url)
        }

        // Already active
        if hasActiveSecurityScope, activeSecurityScopedURL == url { return }

        // Start for new URL
        let started = url.startAccessingSecurityScopedResource()
        if started {
            activeSecurityScopedURL = url
            hasActiveSecurityScope = true
        } else {
            // Not always fatal on macOS; on iOS it often means you picked something non-scoped
            print("startAccessingSecurityScopedResource() returned false for: \(url)")
        }
    }

    private func endSecurityScope() {
        if let current = activeSecurityScopedURL, hasActiveSecurityScope {
            current.stopAccessingSecurityScopedResource()
        }
        hasActiveSecurityScope = false
        activeSecurityScopedURL = nil
    }

    func loadLastLibrary() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var isStale = false
        do {
#if os(macOS)
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
#else
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [], // iOS bookmarks don't use .withSecurityScope
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
#endif

            if isStale {
                // Refresh bookmark if needed
#if os(macOS)
                if let newData = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(newData, forKey: bookmarkKey)
                }
#else
                if let newData = try? url.bookmarkData(
                    options: [], // or [.minimalBookmark]
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(newData, forKey: bookmarkKey)
                }
#endif
            }

            // Keep the scope open for ongoing access.
            beginSecurityScope(for: url)

            wipeTransientEditingFiles(in: url)
            let store = try LibraryStore(at: url)
            self.selectedLibraryURL = url
            self.assets = try store.fetchAllAssets()
            loadEntityProfiles(from: url)

            switch defaultHomePage {
            case "allAssets": self.sidebarSelection = [.allAssets]
            case "actorGallery": self.sidebarSelection = [.actorGallery]
            case "tagGallery": self.sidebarSelection = [.tagGallery]
            default: self.sidebarSelection = [.dashboard]
            }

        } catch {
            print("Bookmark resolution failed: \(error)")
        }
    }

    // MARK: - Multi-library session (federated view)

    /// Refreshes `assets` from EVERY open library via the session — the one
    /// way reload paths fetch, so none can accidentally drop an attachment's
    /// rows. With no attachments this is exactly the old single-library fetch.
    private func reloadUnionAssets(announceClones: Bool = false, refreshGrid: Bool = true) {
        do {
            let load = try LibrarySession.shared.fetchUnionAssets()
            self.assets = load.assets
            if refreshGrid { self.gridRefreshID = UUID() }
            if announceClones, !load.excludedCloneCounts.isEmpty {
                let total = load.excludedCloneCounts.values.reduce(0, +)
                AppErrorReporter.report(
                    "\(total) video\(total == 1 ? " is an identical catalog entry" : "s are identical catalog entries") to an open library and shown once.")
            }
        } catch {
            print("Failed to reload assets: \(error)")
            AppErrorReporter.report("Couldn't reload the library list: \(error.localizedDescription)")
        }
    }

    /// Attaches a second (third, …) library to the session: validates it,
    /// claims its security scope for the session's lifetime, scans it for new
    /// files, splices its rows into the union, and backfills any missing
    /// cached visuals. Never persisted — a relaunch reopens the primary alone.
    func attachLibrary(at pickedURL: URL) {
        guard selectedLibraryURL != nil else { return }
        let standardized = pickedURL.standardizedFileURL
        guard !LibrarySession.shared.allURLs.contains(where: { $0.standardizedFileURL == standardized }) else {
            AppErrorReporter.report("That library is already open.")
            return
        }
        // Attach first so the session's scope claim covers the validation
        // read (picker URLs need scoped access before any file I/O).
        LibrarySession.shared.attach(pickedURL)
        guard FileManager.default.fileExists(atPath: pickedURL.appendingPathComponent(".catalog").path) else {
            LibrarySession.shared.detach(pickedURL)
            AppErrorReporter.report("That folder isn't a ViLM library — open it once as a main library to create its catalog first.")
            return
        }
        wipeTransientEditingFiles(in: pickedURL)
        Task {
            do {
                try await ScopedOperation.run(holding: [pickedURL]) {
                    let store = try LibraryStore(at: pickedURL)
                    try await LibraryScanner(store: store).scan(at: pickedURL)
                }
            } catch {
                AppErrorReporter.report("Attached-library scan problem: \(error.localizedDescription)")
            }
            reloadUnionAssets(announceClones: true)
            if let primary = selectedLibraryURL { loadEntityProfiles(from: primary) }

            // Backfill missing visuals for the attachment (generators skip
            // existing files, so an already-thumbnailed library races through).
            Task {
                await ScopedOperation.run(holding: [pickedURL]) {
                    guard let store = try? LibraryStore(at: pickedURL),
                          let rows = try? store.fetchAllAssets() else { return }
                    let service = ContactSheetService(store: store)
                    var lastRefresh = Date.distantPast
                    for asset in rows {
                        try? await service.generateContactSheet(for: asset, libraryURL: pickedURL)
                        try? await service.generateSingleThumbnail(for: asset, libraryURL: pickedURL)
                        if Date().timeIntervalSince(lastRefresh) >= 1.5 {
                            lastRefresh = Date()
                            await MainActor.run { self.gridRefreshID = UUID() }
                        }
                    }
                    await MainActor.run { self.gridRefreshID = UUID() }
                }
            }
        }
    }

    /// Detaches one library from the session (its scope, connection, and
    /// rows go with it — nothing on disk changes).
    func detachLibrary(at url: URL) {
        LibrarySession.shared.detach(url)
        reloadUnionAssets()
        if let primary = selectedLibraryURL { loadEntityProfiles(from: primary) }
    }

    /// `.catalog/editing` holds in-progress edit copies that only a
    /// *successful* edit cleans up — after a crash mid-edit they'd linger
    /// (multi-GB video files) for the library's lifetime. No edit can be in
    /// flight at open time, so wiping here is always safe (DEFECT_INVENTORY M3).
    private func wipeTransientEditingFiles(in libraryURL: URL) {
        try? FileManager.default.removeItem(
            at: libraryURL.appendingPathComponent(".catalog/editing", isDirectory: true))
    }

    func processFolder(at url: URL) {
        // Scope stays open for the life of the active library (no defer stop).
        beginSecurityScope(for: url)
        wipeTransientEditingFiles(in: url)

        let catalogURL = url.appendingPathComponent(".catalog")
        let thumbsURL = catalogURL.appendingPathComponent("thumbnails")

        // IMPORTANT: align with ContactSheetService output
        let sheetsURL = catalogURL.appendingPathComponent("contactSheets")

        do {
            try FileManager.default.createDirectory(at: thumbsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sheetsURL, withIntermediateDirectories: true)

            let store = try LibraryStore(at: url)
            let scanner = LibraryScanner(store: store)
            let service = ContactSheetService(store: store)

            Task {
                do {
                    // The scan holds its own claim on the library's security
                    // scope: switching libraries mid-scan revokes the session
                    // scope (beginSecurityScope), which used to cut off file
                    // access under this loop (DEFECT_INVENTORY H5).
                    try await ScopedOperation.run(holding: [url]) {
                        try await scanner.scan(at: url)
                    }
                    let initialAssets = try store.fetchAllAssets()

                    await MainActor.run {
                        self.selectedLibraryURL = url
                        self.assets = initialAssets
                        loadEntityProfiles(from: url)

                        switch defaultHomePage {
                        case "allAssets": self.sidebarSelection = [.allAssets]
                        case "actorGallery": self.sidebarSelection = [.actorGallery]
                        case "tagGallery": self.sidebarSelection = [.tagGallery]
                        default: self.sidebarSelection = [.dashboard]
                        }

#if os(macOS)
                        if let bookmarkData = try? url.bookmarkData(
                            options: [.withSecurityScope],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
                        }
#else
                        if let bookmarkData = try? url.bookmarkData(
                            options: [], // or [.minimalBookmark]
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
                        }
#endif
                    }

                    // Generate images in background task to not block UI updates.
                    Task {
                        // This long-running loop holds its own scope claim too
                        // (H5, same as the scan above) — it can still be
                        // generating thumbnails minutes after a library switch.
                        await ScopedOperation.run(holding: [url]) {
                            // Refreshing the grid after every single thumbnail
                            // thrashes the UI on large imports. Coalesce to at most
                            // one refresh every ~1.5s; the per-thumbnail views pick
                            // up newly-generated files on each refresh tick.
                            var lastRefresh = Date.distantPast
                            let refreshInterval: TimeInterval = 1.5

                            for asset in initialAssets {
                                try? await service.generateContactSheet(for: asset, libraryURL: url)
                                try? await service.generateSingleThumbnail(for: asset, libraryURL: url)

                                if Date().timeIntervalSince(lastRefresh) >= refreshInterval {
                                    lastRefresh = Date()
                                    await MainActor.run {
                                        self.gridRefreshID = UUID()
                                    }
                                }
                            }

                            // FINAL REFRESH: ensures the UI sees the new files on disk
                            let finalAssets = (try? store.fetchAllAssets()) ?? initialAssets
                            await MainActor.run {
                                self.assets = finalAssets
                                self.gridRefreshID = UUID()
                            }
                        }
                    }
                } catch {
                    print("Scan failed: \(error)")
                    AppErrorReporter.report("Library scan problem: \(error.localizedDescription)")
                }
            }
        } catch {
            print("Init failed: \(error)")
        }
    }

    private func loadSmartCollections(from url: URL) {
        do {
            let store = try LibraryStore(at: url)
            self.smartCollections = try store.fetchAllSmartCollections()
        } catch {
            print("Failed to load smart collections: \(error)")
        }
    }

    // Single shared load for every entity profile (actor/studio/tag/series)
    // plus the profile photos directory listing, replacing what used to be
    // five separate per-view fetches of the same data. The DB read and
    // directory listing run off the main thread — this fires on every
    // "ReloadAssets", and a large library shouldn't hitch the UI for it.
    private func loadEntityProfiles(from url: URL) {
        // Every open library contributes: profiles fold into a display-only
        // merged view (higher precedence wins conflicts, lists union — never
        // written back), photo-file listings union (an actor whose photos
        // live only in an attachment must not read as photo-less), and the
        // session learns which libraries contain each profile so edits and
        // downloads target the owning one.
        let openURLs = LibrarySession.shared.allURLs
        Task.detached(priority: .userInitiated) {
            do {
                var layers: [[String: EntityProfile]] = []
                var fileNamesUnion = Set<String>()
                for libURL in openURLs {
                    let store = try LibraryStore(at: libURL)
                    // A studio is a string until it has a profile, and a string
                    // can never carry a lookup result — so an unpromoted studio
                    // can never be confirmed, and an unconfirmed studio cannot
                    // drive a folder name.
                    //
                    // ⚠️ ONCE PER LIBRARY PER SESSION. This sits on a hot path:
                    // profiles reload from eleven call sites plus the general
                    // "library data changed" notification, so running it every
                    // time meant a database round-trip per attached library on
                    // every refresh. New studios only ever arrive through an
                    // edit or a match, both of which end in a reload — so the
                    // next launch picks them up, and nothing is lost by not
                    // re-checking continuously.
                    //
                    // Failure is not fatal: the library still opens and the
                    // studios stay unpromoted until next launch.
                    if await LibrarySession.shared.markStudiosPromoted(libURL) {
                        try? store.promoteStudioProfiles()
                    }
                    let profiles = try store.fetchAllEntityProfiles()
                    layers.append(Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }))
                    let dir = libURL.appendingPathComponent(".catalog/profiles")
                    if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                        fileNamesUnion.formUnion(names)
                    }
                }

                let merged = MergeSemantics.mergedProfileView(ordered: layers)

                var newAkaMap: [String: String] = [:]
                for profile in merged.values where profile.id.hasPrefix("actor:") {
                    let mainName = String(profile.id.dropFirst(6))
                    for aka in profile.akas {
                        newAkaMap[aka] = mainName
                    }
                }

                var presence: [String: [URL]] = [:]
                for (libURL, layer) in zip(openURLs, layers) {
                    for id in layer.keys {
                        presence[id, default: []].append(libURL)
                    }
                }

                let finalProfiles = merged
                let finalAkaMap = newAkaMap
                let finalFileNames = fileNamesUnion
                let finalPresence = presence
                await MainActor.run {
                    self.entityProfiles = finalProfiles
                    self.akaMap = finalAkaMap
                    self.profileImageFileNames = finalFileNames
                    LibrarySession.shared.setProfilePresence(finalPresence)
                }
            } catch {
                print("Failed to load entity profiles: \(error)")
                // Every dependent screen (Dashboard attention lists, actor
                // gallery, filters) silently computes against stale/empty
                // profile data until the next reload — the user must know
                // (DEFECT_INVENTORY L8).
                AppErrorReporter.report("Couldn't load actor profiles — galleries and filters may be incomplete. Pull to refresh or reopen the library.")
            }
        }
    }
}

#if os(iOS)
// MARK: - iOS Folder Picker (UIDocumentPickerViewController)
private struct LibraryFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
#endif
