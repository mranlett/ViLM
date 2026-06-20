import SwiftUI
import LibraryCore

struct AssetsGridView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    @Binding var searchText: String
    @Binding var selectedAssetIDs: Set<Asset.ID>
    let missingAssetIDs: Set<Asset.ID>
    @State private var gridStyle: GridStyle = .singleFrame
    @State private var isEditMode: Bool = false
    let libraryURL: URL?
    let refreshID: UUID
    @State private var isShowingFilterBuilder = false
    
    enum GridStyle {
        case singleFrame
        case contactSheet
    }
    
    // MARK: - Filter Logic
    private var filteredAssets: [Asset] {
        assets.filter { asset in
            let matchesCategory = sidebarSelection.isEmpty ? true : sidebarSelection.allSatisfy { item in
                switch item {
                case .allAssets: return true
                case .actor(let name): return asset.tags.contains("actor:\(name)")
                case .tag(let name): return asset.tags.contains("tag:\(name)")
                case .studio(let name): return asset.tags.contains("studio:\(name)")
                }
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
        if sidebarSelection.count > 1 { return "Multiple Filters" }
        guard let first = sidebarSelection.first else { return "All Assets" }
        switch first {
        case .allAssets: return "All Assets"
        case .actor(let name): return name
        case .tag(let name): return name
        case .studio(let name): return name
        }
    }
    
    // MARK: - Body
    var body: some View {
        ScrollView {
            if sidebarSelection.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(sidebarSelection).sorted(by: { sidebarSelectionTitle(for: $0) < sidebarSelectionTitle(for: $1) }), id: \.self) { item in
                            if item != .allAssets {
                                TagBubble(label: sidebarSelectionTitle(for: item), color: color(for: item), onDelete: {
                                    sidebarSelection.remove(item)
                                    if sidebarSelection.isEmpty {
                                        sidebarSelection = [.allAssets]
                                    }
                                })
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top)
            } else if sidebarSelection.count == 1, let first = sidebarSelection.first, first != .allAssets {
                ProfileGraphHeaderView(
                    filteredAssets: filteredAssets,
                    sidebarSelection: $sidebarSelection,
                    currentSelection: first,
                    libraryURL: libraryURL
                )
                .padding(.top)
            }
            
            if filteredAssets.isEmpty {
                emptyStateView // Use the helper view here
                    .padding(.top, 100)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 20) {
                    ForEach(filteredAssets) { asset in
#if os(iOS)
                        if isEditMode {
                            gridItem(for: asset)
                                .onTapGesture {
                                    if selectedAssetIDs.contains(asset.id) {
                                        selectedAssetIDs.remove(asset.id)
                                    } else {
                                        selectedAssetIDs.insert(asset.id)
                                    }
                                }
                        } else {
                            NavigationLink(value: asset.id) {
                                gridItem(for: asset)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded {
                                selectedAssetIDs = [asset.id]
                            })
                        }
#else
                        gridItem(for: asset)
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.command) {
                                    if selectedAssetIDs.contains(asset.id) {
                                        selectedAssetIDs.remove(asset.id)
                                    } else {
                                        selectedAssetIDs.insert(asset.id)
                                    }
                                } else {
                                    selectedAssetIDs = [asset.id]
                                }
                            }
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
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button(action: { isShowingFilterBuilder = true }) {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    gridStylePicker
                }
            }
#if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditMode ? "Done" : "Select") {
                    isEditMode.toggle()
                    if !isEditMode {
                        selectedAssetIDs.removeAll()
                    }
                }
            }
            if isEditMode && selectedAssetIDs.count > 1 {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: selectedAssetIDs) {
                        Text("Batch Edit (\(selectedAssetIDs.count))")
                            .font(.headline)
                    }
                }
            }
#endif
        }
        .sheet(isPresented: $isShowingFilterBuilder) {
            FilterBuilderView(assets: assets, sidebarSelection: $sidebarSelection)
        }
    }
    
    // MARK: - Sub-Expressions (Helpers to fix compiler error)
    
    private func sidebarSelectionTitle(for item: SidebarItem) -> String {
        switch item {
        case .allAssets: return "All"
        case .actor(let name): return name
        case .tag(let name): return name
        case .studio(let name): return name
        }
    }
    
    private func color(for item: SidebarItem) -> Color {
        switch item {
        case .allAssets: return .gray
        case .actor: return .blue
        case .tag: return .green
        case .studio: return .purple
        }
    }
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
        .background(selectedAssetIDs.contains(asset.id) ? Color.blue.opacity(0.15) : Color.clear)
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
            if missingAssetIDs.contains(asset.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .background(Color.black.opacity(0.4).clipShape(Circle()))
                    .padding(8)
            } else if asset.status == .reviewed {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .background(Color.black.opacity(0.4).clipShape(Circle()))
                    .padding(8)
            }
        }
    }
}
