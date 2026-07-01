import SwiftUI
import LibraryCore

struct AssetFilterCriteria: Equatable {
    enum Logic: String, CaseIterable, Equatable { case and = "AND", or = "OR" }
    enum ReviewStatusFilter: String, CaseIterable, Equatable { case all = "All", reviewed = "Reviewed", unreviewed = "Unreviewed" }

    var reviewStatus: ReviewStatusFilter = .all
    var minRating: Int? = nil
    
    var actorsLogic: Logic = .and
    var selectedActors: Set<String> = []
    
    var tagsLogic: Logic = .and
    var selectedTags: Set<String> = []
    
    var studiosLogic: Logic = .and
    var selectedStudios: Set<String> = []
    
    var isEmpty: Bool {
        reviewStatus == .all && minRating == nil && selectedActors.isEmpty && selectedTags.isEmpty && selectedStudios.isEmpty
    }
}

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
    
    enum SortOption: String, CaseIterable {
        case name = "Name"
        case date = "Date Added"
        case size = "File Size"
    }
    
    @State private var sortOption: SortOption = .name
    @State private var sortAscending: Bool = true
    @State private var fileSizes: [Asset.ID: Int64] = [:]
    
    @State private var filterCriteria = AssetFilterCriteria()
    
    enum GridStyle {
        case singleFrame
        case contactSheet
    }
    
    // MARK: - Filter Logic
    private var filteredAssets: [Asset] {
        let filtered = assets.filter { asset in
            let matchesCategory = sidebarSelection.isEmpty ? true : sidebarSelection.allSatisfy { item in
                switch item {
                case .allAssets, .actorGallery, .tagGallery: return true
                case .actor(let name): return asset.tags.contains("actor:\(name)")
                case .tag(let name): return asset.tags.contains("tag:\(name)")
                case .studio(let name): return asset.tags.contains("studio:\(name)")
                case .series(let name): return asset.videoName == name
                }
            }
            
            if !matchesCategory { return false }
            
            let matchesReviewStatus: Bool
            switch filterCriteria.reviewStatus {
            case .all: matchesReviewStatus = true
            case .reviewed: matchesReviewStatus = asset.status == .reviewed
            case .unreviewed: matchesReviewStatus = asset.status == .unreviewed
            }
            
            if !matchesReviewStatus { return false }
            
            if let minRating = filterCriteria.minRating {
                let assetRating = asset.rating ?? 0
                if assetRating < minRating { return false }
            }
            
            // Actors Filter
            if !filterCriteria.selectedActors.isEmpty {
                let assetActors = Set(asset.actors)
                if filterCriteria.actorsLogic == .and {
                    if !filterCriteria.selectedActors.isSubset(of: assetActors) { return false }
                } else {
                    if filterCriteria.selectedActors.isDisjoint(with: assetActors) { return false }
                }
            }
            
            // Tags Filter
            if !filterCriteria.selectedTags.isEmpty {
                let assetTags = Set(asset.actions)
                if filterCriteria.tagsLogic == .and {
                    if !filterCriteria.selectedTags.isSubset(of: assetTags) { return false }
                } else {
                    if filterCriteria.selectedTags.isDisjoint(with: assetTags) { return false }
                }
            }
            
            // Studios Filter
            if !filterCriteria.selectedStudios.isEmpty {
                let assetStudios = Set(asset.studios)
                if filterCriteria.studiosLogic == .and {
                    if !filterCriteria.selectedStudios.isSubset(of: assetStudios) { return false }
                } else {
                    if filterCriteria.selectedStudios.isDisjoint(with: assetStudios) { return false }
                }
            }
            
            if !searchText.isEmpty && !asset.fileName.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            
            return true
        }
        
        return filtered.sorted { a, b in
            let compare: Bool
            switch sortOption {
            case .name:
                compare = a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            case .date:
                compare = a.createdAt < b.createdAt
            case .size:
                let sizeA = fileSizes[a.id] ?? 0
                let sizeB = fileSizes[b.id] ?? 0
                compare = sizeA < sizeB
            }
            return sortAscending ? compare : !compare
        }
    }
    
    // MARK: - Title Logic
    private var sidebarSelectionTitle: String {
        if sidebarSelection.count > 1 { return "Multiple Filters" }
        guard let first = sidebarSelection.first else { return "All Assets" }
        switch first {
        case .allAssets: return "All Assets"
        case .actorGallery: return "Actors Gallery"
        case .tagGallery: return "Tags Gallery"
        case .actor(let name): return name
        case .tag(let name): return name
        case .studio(let name): return name
        case .series(let name): return name
        }
    }
    
    // MARK: - Body
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
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
                                NavigationLink(value: AppRoute.asset(asset.id)) {
                                    gridItem(for: asset)
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(TapGesture().onEnded {
                                    selectedAssetIDs = [asset.id]
                                })
                            }
#else
                            Button(action: {
                                if NSEvent.modifierFlags.contains(.command) {
                                    if selectedAssetIDs.contains(asset.id) {
                                        selectedAssetIDs.remove(asset.id)
                                    } else {
                                        selectedAssetIDs.insert(asset.id)
                                    }
                                } else {
                                    selectedAssetIDs = [asset.id]
                                }
                            }) {
                                gridItem(for: asset)
                            }
                            .buttonStyle(.plain)
#endif
                        }
                        
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(refreshID)
        .navigationTitle(sidebarSelectionTitle)
        .navigationSubtitle("\(filteredAssets.count) items")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search filenames...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Menu {
                        Picker("Sort By", selection: $sortOption) {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Divider()
                        Button(action: { sortAscending.toggle() }) {
                            Label(sortAscending ? "Ascending" : "Descending", systemImage: sortAscending ? "arrow.up" : "arrow.down")
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    
                    Button(action: { isShowingFilterBuilder = true }) {
                        Label("Filter", systemImage: filterCriteria.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
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
            if isEditMode && !selectedAssetIDs.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: AppRoute.assets(selectedAssetIDs)) {
                        Text("Edit \(selectedAssetIDs.count) Selected")
                            .font(.headline)
                    }
                }
            }
#endif
        }
        .sheet(isPresented: $isShowingFilterBuilder) {
            FilterBuilderView(assets: assets, criteria: $filterCriteria)
        }
        .task(id: assets.count) {
            guard let url = libraryURL else { return }
            var newSizes: [Asset.ID: Int64] = [:]
            for asset in assets {
                let fileURL = url.appendingPathComponent(asset.relativePath)
                if let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attr[.size] as? Int64 {
                    newSizes[asset.id] = size
                }
            }
            await MainActor.run {
                self.fileSizes = newSizes
            }
        }
    }
    
    // MARK: - Sub-Expressions (Helpers to fix compiler error)
    
    private func sidebarSelectionTitle(for item: SidebarItem) -> String {
        switch item {
        case .allAssets: return "All"
        case .actorGallery: return "Actors Gallery"
        case .tagGallery: return "Tags Gallery"
        case .actor(let name): return name
        case .tag(let name): return name
        case .studio(let name): return name
        case .series(let name): return name
        }
    }
    
    private func color(for item: SidebarItem) -> Color {
        switch item {
        case .actor: return .blue
        case .tag: return .green
        case .studio: return .purple
        case .series: return .orange
        default: return .gray
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
