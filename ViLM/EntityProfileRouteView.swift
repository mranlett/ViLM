// EntityProfileRouteView.swift
// The actor/studio/tag/series profile page: wraps AssetsGridView with a local
// sidebar selection pinned to one entity, so the grid renders that entity's
// header (ProfileGraphHeaderView) plus its filtered videos. Pushed by
// navigation on iPhone and shown in the split view's detail pane on
// iPad/macOS.

import SwiftUI
import LibraryCore

struct EntityProfileRouteView: View {
    let category: String
    let name: String
    let assets: [Asset]
    let libraryURL: URL?
    let gridRefreshID: UUID
    let entityProfiles: EntityProfileIndex
    let akaMap: [String: String]
    @State private var localSelection: Set<SidebarItem>
    @State private var searchText = ""
    @State private var selectedAssetIDs: Set<Asset.ID> = []
    @State private var missingAssetIDs: Set<Asset.ID> = []
    @State private var filteredAssetContext: [Asset.ID] = []

    init(category: String, name: String, assets: [Asset], libraryURL: URL?, gridRefreshID: UUID, entityProfiles: EntityProfileIndex = .empty, akaMap: [String: String] = [:]) {
        self.category = category
        self.name = name
        self.assets = assets
        self.libraryURL = libraryURL
        self.gridRefreshID = gridRefreshID
        self.entityProfiles = entityProfiles
        self.akaMap = akaMap

        let item: SidebarItem
        switch category {
        // An actor pill may carry an AKA ("Dahlia" for Bailey). Resolve to the
        // canonical name HERE: the grid's AKA resolution lives in
        // .onChange(of: sidebarSelection), which never fires for this pinned
        // initial value — so an unresolved AKA would render a blank profile
        // with no videos.
        case "actor": item = .actor(akaMap[name] ?? name)
        case "studio": item = .studio(name)
        case "series": item = .series(name)
        default: item = .tag(name)
        }
        self._localSelection = State(initialValue: [item])
    }

    var body: some View {
        AssetsGridView(
            assets: assets,
            sidebarSelection: $localSelection,
            searchText: $searchText,
            selectedAssetIDs: $selectedAssetIDs,
            missingAssetIDs: missingAssetIDs,
            libraryURL: libraryURL,
            refreshID: gridRefreshID,
            // ⚠️ This grid must NOT claim the window's search field.
            //
            // On the macOS split layout a profile page opens in the detail
            // column while the browse column still holds its own grid — two
            // `.searchable` views in one window, both claiming the toolbar
            // identifier `com.apple.SwiftUI.search`, which AppKit rejects by
            // crashing. Clicking an actor in the gallery did it every time.
            providesSearchField: false,
            // ⭐ This grid lives IN the detail column, so a selection has
            // nowhere to be shown. Push instead, which also leaves a way back
            // to the profile.
            pushesVideoDetail: true,
            filteredAssetContext: $filteredAssetContext,
            entityProfiles: entityProfiles,
            akaMap: akaMap,
            pendingFilter: .constant(nil),
            pendingSort: .constant(nil),
            pendingSortAscending: .constant(nil)
        )
    }
}
