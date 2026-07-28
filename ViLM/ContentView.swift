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
    case actor(String)
    case tag(String)
    case studio(String)
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
                    Task {
                        do {
                            let store = try LibraryStore(at: url)
                            let updatedAssets = try store.fetchAllAssets()
                            await MainActor.run {
                                self.assets = updatedAssets
                                self.gridRefreshID = UUID()
                            }
                        } catch {
                            print("Failed to reload assets: \(error)")
                        }
                    }
                }
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
                        onRefresh: {
                            do {
                                let store = try LibraryStore(at: url)
                                self.assets = try store.fetchAllAssets()
                                self.gridRefreshID = UUID()
                            } catch {
                                print("Refresh failed: \(error)")
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: $isShowingDuplicateDetection) {
                if let url = selectedLibraryURL {
                    DuplicateDetectionView(
                        libraryURL: url,
                        assets: assets,
                        onRefresh: {
                            do {
                                let store = try LibraryStore(at: url)
                                self.assets = try store.fetchAllAssets()
                                self.gridRefreshID = UUID()
                            } catch {
                                print("Refresh failed: \(error)")
                            }
                        }
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
            .sheet(isPresented: $isShowingTagCleanup) {
                if let url = selectedLibraryURL {
                    TagCleanupView(
                        libraryURL: url,
                        assets: assets,
                        onRefresh: {
                            do {
                                let store = try LibraryStore(at: url)
                                self.assets = try store.fetchAllAssets()
                                self.gridRefreshID = UUID()
                                loadEntityProfiles(from: url)
                            } catch {
                                print("Refresh failed: \(error)")
                            }
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
                }
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
                onApplyFilters: {}
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
                smartCollections: smartCollections
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

    // MARK: - Quick Actions

    private func performPendingQuickActionIfReady() {
        guard let action = quickActionRouter.pending else { return }
        // Wait until the library + its assets have loaded (a cold launch from a
        // quick action reaches here before loadLastLibrary() finishes).
        guard selectedLibraryURL != nil, !assets.isEmpty else { return }
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
        deferUntilSettingsDismissed {
#if os(iOS)
            if horizontalSizeClass == .compact {
                sidebarSelection = [.allAssets]
                selectedAssetIDs = [assetID]
                navigationPath = [.browse, .asset(assetID, context: filteredAssetContext)]
                return
            }
#endif
            sidebarSelection = [.allAssets]
            selectedAssetIDs = [assetID]
            columnVisibility = .all
        }
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
        guard let url = selectedLibraryURL else { return }
        do {
            let store = try LibraryStore(at: url)
            let scanner = LibraryScanner(store: store)
            let service = ContactSheetService(store: store)

            // 1. Check for new files
            try await scanner.scan(at: url)

            // 2. Refresh assets and entity profiles in memory
            let updatedAssets = try store.fetchAllAssets()
            await MainActor.run {
                self.assets = updatedAssets
                loadEntityProfiles(from: url)
            }

            // 3. Generate thumbnails for any missing ones
            for asset in updatedAssets {
                try? await service.generateContactSheet(for: asset, libraryURL: url)
                try? await service.generateSingleThumbnail(for: asset, libraryURL: url)
            }

            // 4. Validate missing files
            var missing: Set<Asset.ID> = []
            for asset in updatedAssets {
                let fileURL = url.appendingPathComponent(asset.relativePath)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    missing.insert(asset.id)
                }
            }

            // 5. Update UI
            await MainActor.run {
                self.missingAssetIDs = missing
                self.gridRefreshID = UUID()
            }
        } catch {
            print("Check for Changes failed: \(error)")
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

    func processFolder(at url: URL) {
        // Scope stays open for the life of the active library (no defer stop).
        beginSecurityScope(for: url)

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
        Task.detached(priority: .userInitiated) {
            do {
                let store = try LibraryStore(at: url)
                let profiles = try store.fetchAllEntityProfiles()

                var dict: [String: EntityProfile] = [:]
                var newAkaMap: [String: String] = [:]
                for profile in profiles {
                    dict[profile.id] = profile
                    if profile.id.hasPrefix("actor:") {
                        let mainName = String(profile.id.dropFirst(6))
                        for aka in profile.akas {
                            newAkaMap[aka] = mainName
                        }
                    }
                }

                let profilesDir = url.appendingPathComponent(".catalog/profiles")
                let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path)).map(Set.init)

                let finalProfiles = dict
                let finalAkaMap = newAkaMap
                await MainActor.run {
                    self.entityProfiles = finalProfiles
                    self.akaMap = finalAkaMap
                    if let fileNames {
                        self.profileImageFileNames = fileNames
                    }
                }
            } catch {
                print("Failed to load entity profiles: \(error)")
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
