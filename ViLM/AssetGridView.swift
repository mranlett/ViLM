import SwiftUI
import LibraryCore

struct AssetsGridView: View {
    let assets: [Asset]
    let sidebarSelection: SidebarItem?
    @Binding var searchText: String
    @Binding var selectedAsset: Asset?
    @State private var gridStyle: GridStyle = .singleFrame
    let libraryURL: URL?
    let refreshID: UUID
    
    enum GridStyle {
        case singleFrame
        case contactSheet
    }
    
    // MARK: - Filter Logic
    private var filteredAssets: [Asset] {
        assets.filter { asset in
            let matchesCategory: Bool
            switch sidebarSelection {
            case .allAssets, .none:
                matchesCategory = true
            case .actor(let name):
                matchesCategory = asset.tags.contains("actor:\(name)")
            case .tag(let name):
                matchesCategory = asset.tags.contains("tag:\(name)")
            }
            
            if searchText.isEmpty {
                return matchesCategory
            } else {
                return matchesCategory && asset.fileName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // MARK: - Title Logic
    private var sidebarSelectionTitle: String {
        switch sidebarSelection {
        case .allAssets, .none: return "All Assets"
        case .actor(let name): return name
        case .tag(let name): return name
        }
    }
    
    // MARK: - Body
    var body: some View {
        ScrollView {
            if filteredAssets.isEmpty {
                emptyStateView // Use the helper view here
                    .padding(.top, 100)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 20) {
                    ForEach(filteredAssets) { asset in
#if os(iOS)
                        NavigationLink(value: asset.id) {
                            gridItem(for: asset)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            selectedAsset = asset
                        })
#else
                        gridItem(for: asset)
                            .onTapGesture { selectedAsset = asset }
#endif
                    }
                    
                }
                .padding()
            }
        }
        .id(refreshID)
        .navigationTitle(sidebarSelectionTitle)
        .navigationSubtitle("\(filteredAssets.count) items")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search filenames...")
        .toolbar {
            gridStylePicker
        }
    }
    
    // MARK: - Sub-Expressions (Helpers to fix compiler error)
    
    @ViewBuilder
    private var emptyStateView: some View {
        let title = searchText.isEmpty ? "No Assets Found" : "No Results for \"\(searchText)\""
        let symbol = searchText.isEmpty ? "film" : "magnifyingglass"
        ContentUnavailableView(title, systemImage: symbol)
    }
    
    @ViewBuilder
    private func gridItem(for asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if gridStyle == .singleFrame {
                    VideoThumbnailView(asset: asset, libraryURL: libraryURL)
                } else {
                    ContactSheetThumbnailView(asset: asset, libraryURL: libraryURL)
                }
            }
            .overlay(statusOverlay(for: asset), alignment: .topTrailing)
            
            Text(asset.fileName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .padding(4)
        .background(selectedAsset?.id == asset.id ? Color.blue.opacity(0.15) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
    
    
    private var gridStylePicker: some View {
        Picker("Grid Style", selection: $gridStyle) {
            Label("Single", systemImage: "photo").tag(GridStyle.singleFrame)
            Label("Grid", systemImage: "square.grid.3x3.fill").tag(GridStyle.contactSheet)
        }
        .pickerStyle(.segmented)
    }
    
    private func statusOverlay(for asset: Asset) -> some View {
        Group {
            if asset.status == .reviewed {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .background(Color.black.opacity(0.4).clipShape(Circle()))
                    .padding(8)
            }
        }
    }
}
