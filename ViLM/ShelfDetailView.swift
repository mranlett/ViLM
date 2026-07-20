// ShelfDetailView.swift
// The "See All" screen for a Smart Shelf: the full, live result of a
// `LibraryQuery` rendered as a grid. Reached via `AppRoute.shelf(...)` and
// always sits inside a navigation stack (the compact `navigationPath` or the
// split-view `detailPath`), so it can push straight to Video Details with a
// plain NavigationLink in both layouts.

import SwiftUI
import LibraryCore

struct ShelfDetailView: View {
    let query: LibraryQuery
    let assets: [Asset]
    let libraryURL: URL?
    @Binding var selectedAssetIDs: Set<Asset.ID>

    var body: some View {
        let items = query.run(assets: assets)
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "rectangle.stack",
                    description: Text("No videos match “\(query.title)” right now.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                    ForEach(items) { asset in
                        NavigationLink(value: AppRoute.asset(asset.id, context: items.map(\.id))) {
                            VideoThumbnailCard(asset: asset, libraryURL: libraryURL)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { selectedAssetIDs = [asset.id] })
                    }
                }
                .padding()
            }
        }
        .background(Color(PlatformSystemGroupedBackground))
        .navigationTitle(query.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
