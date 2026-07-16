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
    let entityProfiles: [String: EntityProfile]
    let akaMap: [String: String]
    @State private var localSelection: Set<SidebarItem>
    @State private var searchText = ""
    @State private var selectedAssetIDs: Set<Asset.ID> = []
    @State private var missingAssetIDs: Set<Asset.ID> = []
    @State private var filteredAssetContext: [Asset.ID] = []

    init(category: String, name: String, assets: [Asset], libraryURL: URL?, gridRefreshID: UUID, entityProfiles: [String: EntityProfile] = [:], akaMap: [String: String] = [:]) {
        self.category = category
        self.name = name
        self.assets = assets
        self.libraryURL = libraryURL
        self.gridRefreshID = gridRefreshID
        self.entityProfiles = entityProfiles
        self.akaMap = akaMap

        let item: SidebarItem
        switch category {
        case "actor": item = .actor(name)
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
            filteredAssetContext: $filteredAssetContext,
            entityProfiles: entityProfiles,
            akaMap: akaMap,
            pendingFilter: .constant(nil),
            pendingSort: .constant(nil),
            pendingSortAscending: .constant(nil)
        )
    }
}
