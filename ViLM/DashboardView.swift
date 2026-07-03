import SwiftUI
import LibraryCore

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

struct DashboardView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    @Binding var selectedAssetIDs: Set<Asset.ID>
    
    let libraryURL: URL?
    
    private var recentlyAdded: [Asset] {
        Array(assets.sorted { $0.createdAt > $1.createdAt }.prefix(10))
    }
    
    private var unreviewed: [Asset] {
        Array(assets.filter { $0.status == .unreviewed }.prefix(10))
    }
    
    // stats
    private var totalActors: Int {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }
        return Set(actorTags).count
    }
    
    private var totalTags: Int {
        let allTags = assets.flatMap { $0.tags }
        let regularTags = allTags.filter { $0.hasPrefix("tag:") }
        return Set(regularTags).count
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // STATS
                HStack(spacing: 20) {
                    StatCard(title: "Total Videos", value: "\(assets.count)")
                    StatCard(title: "Total Actors", value: "\(totalActors)")
                    StatCard(title: "Total Tags", value: "\(totalTags)")
                }
                .padding(.horizontal)
                
                // RECENTLY ADDED
                if !recentlyAdded.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Recently Added").font(.title2).bold().padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                ForEach(recentlyAdded) { asset in
                                    assetButton(for: asset, context: recentlyAdded.map { $0.id })
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                
                // UNREVIEWED
                if !unreviewed.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Unreviewed Videos").font(.title2).bold().padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                ForEach(unreviewed) { asset in
                                    assetButton(for: asset, context: unreviewed.map { $0.id })
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Dashboard")
    }
    
    @ViewBuilder
    private func assetButton(for asset: Asset, context: [Asset.ID]) -> some View {
        #if os(iOS)
        NavigationLink(value: AppRoute.asset(asset.id, context: context)) {
            gridItem(for: asset)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            selectedAssetIDs = [asset.id]
        })
        #else
        Button(action: {
            selectedAssetIDs = [asset.id]
        }) {
            gridItem(for: asset)
        }
        .buttonStyle(.plain)
        #endif
    }
    
    @ViewBuilder
    private func gridItem(for asset: Asset) -> some View {
        VStack {
            VideoThumbnailView(asset: asset, libraryURL: libraryURL)
                .frame(width: 160, height: 90)
                .cornerRadius(8)
            Text(asset.fileName)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 160)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline).foregroundColor(.secondary)
            Text(value).font(.title).bold()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
}
