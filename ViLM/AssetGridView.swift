// AssetGridView.swift
// The All Assets grid: the search/filter/sort pipeline (cached in
// displayedAssets, recomputed only when inputs change), season-grouped series
// view, the Videos/Actors results toggle, multi-select editing, and smart
// collection saving.

import SwiftUI
import LibraryCore

struct AssetsGridView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    @Binding var searchText: String
    // The search field itself binds to `searchText` directly so typing feels
    // instant; the (potentially expensive, full-library) recompute below
    // reacts to this debounced copy instead, so a fast typist doesn't
    // trigger a re-filter on every keystroke.
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @Binding var selectedAssetIDs: Set<Asset.ID>
    let missingAssetIDs: Set<Asset.ID>
    @AppStorage("assetGridStyle") private var gridStyle: GridStyle = .singleFrame
    @State private var isEditMode: Bool = false
    @State private var isShowingHelp = false
    let libraryURL: URL?
    let refreshID: UUID
    @Binding var filteredAssetContext: [Asset.ID]
    var onPullToRefresh: () async -> Void = {}

    // Loaded once at the ContentView level and shared across every screen
    // that needs entity profiles, instead of each screen independently
    // re-fetching the same data on its own `.onAppear`.
    let entityProfiles: [String: EntityProfile]
    let akaMap: [String: String]

    @Environment(\.usesStackNavigation) private var usesStackNavigation
    
    @Binding var pendingFilter: AssetFilterCriteria?
    @Binding var pendingSort: SortOption?
    @Binding var pendingSortAscending: Bool?
    
    @State private var isShowingFilterBuilder = false
    @State private var isShowingSaveCollection = false
    @State private var newCollectionName = ""

    enum ResultViewMode: String, CaseIterable {
        case assets = "Videos"
        case actors = "Actors"
    }
    // Only meaningful while searching — reset to .assets once the search is
    // cleared so the toggle doesn't linger showing actors for an empty query.
    @State private var resultViewMode: ResultViewMode = .assets
    
    enum SortOption: String, CaseIterable {
        case seriesOrder = "Series Order"
        case name = "Name"
        case date = "Date Added"
        case size = "File Size"
    }
    
    @State private var sortOption: SortOption = .name
    @State private var sortAscending: Bool = true
    @State private var fileSizes: [Asset.ID: Int64] = [:]
    @State private var hasLoadedDefaults = false
    
    @AppStorage("defaultAssetFiltersStr") private var defaultFilterCriteriaStr: String = ""
    private var defaultFilterCriteria: AssetFilterCriteria {
        get {
            guard let data = defaultFilterCriteriaStr.data(using: .utf8),
                  let result = try? JSONDecoder().decode(AssetFilterCriteria.self, from: data) else {
                return AssetFilterCriteria()
            }
            return result
        }
    }
    
    @State private var filterCriteria = AssetFilterCriteria()
    
    enum GridStyle: String {
        case singleFrame
        case contactSheet
    }
    
    // MARK: - Filter Logic

    // Cached result of computeFilteredAssets(). The pipeline walks every
    // asset and sorts; recomputing it inside `body` (which runs per keystroke
    // and per selection change) does not scale, so it only reruns when one of
    // its inputs changes — see the onChange modifiers on the grid.
    @State private var displayedAssets: [Asset] = []
    // Seasons the user has collapsed in the grouped series view (nil season = Int.min).
    @State private var collapsedSeasons: Set<Int> = []

    // Bundles the cheap-to-compare filter inputs for a single onChange.
    private struct FilterInputs: Equatable {
        let sidebarSelection: Set<SidebarItem>
        let searchText: String
        let filterCriteria: AssetFilterCriteria
        let sortOption: SortOption
        let sortAscending: Bool
    }

    private var filterInputs: FilterInputs {
        FilterInputs(
            sidebarSelection: sidebarSelection,
            searchText: debouncedSearchText,
            filterCriteria: filterCriteria,
            sortOption: sortOption,
            sortAscending: sortAscending
        )
    }

    // Everything the cached result depends on. When this changes the cache is
    // rebuilt; file sizes only matter while sorting by size.
    private struct RecomputeSignature: Equatable {
        let inputs: FilterInputs
        let assets: [Asset]
        let entityProfiles: [String: EntityProfile]
        let akaMap: [String: String]
        let fileSizes: [Asset.ID: Int64]?
    }

    // Reloads file sizes when the library changes or size-sort is turned on.
    private struct FileSizeTrigger: Equatable {
        let assetCount: Int
        let sortBySize: Bool
    }

    private var recomputeSignature: RecomputeSignature {
        RecomputeSignature(
            inputs: filterInputs,
            assets: assets,
            entityProfiles: entityProfiles,
            akaMap: akaMap,
            fileSizes: sortOption == .size ? fileSizes : nil
        )
    }

    private func recomputeDisplayedAssets() {
        displayedAssets = computeFilteredAssets()
        filteredAssetContext = displayedAssets.map(\.id)
    }

    private func computeFilteredAssets() -> [Asset] {
        let filtered = assets.filter { asset in
            let matchesCategory = sidebarSelection.isEmpty ? true : sidebarSelection.allSatisfy { item in
                switch item {
                case .dashboard, .allAssets, .actorGallery, .tagGallery, .seriesGallery, .smartCollection: return true
                case .actor(let name): return mappedActors(for: asset).contains(name)
                case .tag(let name):
                    // A tag can apply directly to a video, or only exist on
                    // an actor's own profile (e.g. "Blonde") — match either,
                    // since Tag Gallery surfaces both kinds under one name.
                    if asset.tags.contains("tag:\(name)") { return true }
                    return mappedActors(for: asset).contains { entityProfiles["actor:\($0)"]?.tags.contains(name) ?? false }
                case .studio(let name): return asset.tags.contains("studio:\(name)")
                case .series(let name): return asset.videoName == name
                }
            }
            
            if !matchesCategory { return false }

            // Review status, rating, and the actor/tag/studio + actor-metadata
            // sets are the persisted filter model — matched by the shared,
            // unit-tested implementation in LibraryCore so this grid and the
            // Move-Between-Libraries page stay in lockstep.
            if !filterCriteria.matches(asset, mappedActors: mappedActors(for: asset), entityProfiles: entityProfiles) {
                return false
            }

            if !matchesSearch(asset, query: debouncedSearchText) {
                return false
            }

            return true
        }
        
        return filtered.sorted { a, b in
            let compare: Bool
            switch sortOption {
            case .seriesOrder:
                compare = seriesOrderIsAscending(a, b)
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

    /// Ordering within a series: season, then episode, then date added, then
    /// filename. A missing season is treated as Season 1 (an unnumbered entry
    /// is the original); a missing episode sorts last within its season so
    /// numbered episodes lead. Used by the "Series Order" sort.
    private func seriesOrderIsAscending(_ a: Asset, _ b: Asset) -> Bool {
        let sa = a.seasonNumber ?? 1
        let sb = b.seasonNumber ?? 1
        if sa != sb { return sa < sb }
        let ea = a.episodeNumber ?? Int.max
        let eb = b.episodeNumber ?? Int.max
        if ea != eb { return ea < eb }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
    }
    
    // MARK: - Title Logic
    private var sidebarSelectionTitle: String {
        if sidebarSelection.count > 1 { return "Multiple Filters" }
        guard let first = sidebarSelection.first else { return "All Assets" }
        switch first {
        case .dashboard: return "Dashboard"
        case .allAssets: return "All Assets"
        case .actorGallery: return "Actors Gallery"
        case .tagGallery: return "Tags Gallery"
        case .seriesGallery: return "Series Gallery"
        case .actor(let name): return name
        case .tag(let name): return name
        case .studio(let name): return name
        case .series(let name): return name
        case .smartCollection(_, let name): return name
        }
    }

    // MARK: - Scroll Content
    private var scrollContent: some View {
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
                        filteredAssets: displayedAssets,
                        sidebarSelection: $sidebarSelection,
                        currentSelection: first,
                        libraryURL: libraryURL
                    )
                    .padding(.top)
                }

                if isFiltered {
                    Picker("View", selection: $resultViewMode) {
                        ForEach(ResultViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                if isFiltered && resultViewMode == .actors {
                    actorsResultGrid
                } else if displayedAssets.isEmpty {
                    emptyStateView // Use the helper view here
                        .padding(.top, 100)
                } else if showSeasonSections {
                    seasonSectionedGrid
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(displayedAssets) { asset in
                            interactiveGridItem(for: asset)
                        }

                    }
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private var actorsResultGrid: some View {
        if matchingActors.isEmpty {
            ContentUnavailableView(
                "No Matching Actors",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("None of the matching videos have an actor tagged.")
            )
            .padding(.top, 100)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 20) {
                ForEach(matchingActors, id: \.self) { actor in
                    actorNavigationWrapper(for: actor) {
                        ActorGridItemView(
                            actor: actor,
                            profile: entityProfiles["actor:\(actor)"],
                            assetsCount: matchingActorsCount(for: actor),
                            isSelected: false,
                            libraryURL: libraryURL
                        )
                    }
                }
            }
            .padding()
        }
    }

    private var seasonSectionedGrid: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(seasonSections) { section in
                let isCollapsed = collapsedSeasons.contains(section.id)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isCollapsed {
                            collapsedSeasons.remove(section.id)
                        } else {
                            collapsedSeasons.insert(section.id)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(seasonLabel(section.season))
                            .font(.headline)
                        Text("\(section.assets.count) video\(section.assets.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.top, 8)
                }
                .buttonStyle(.plain)

                if !isCollapsed {
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(section.assets) { asset in
                            interactiveGridItem(for: asset)
                        }
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - State-managed content
    // Split from `body` so neither modifier chain is long enough to blow the
    // Swift type-checker's budget.
    private var stateManagedContent: some View {
        scrollContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .refreshable { await onPullToRefresh() }
        #endif
        .onChange(of: recomputeSignature) { _, _ in
            recomputeDisplayedAssets()
        }
        .onChange(of: akaMap) { _, newAkaMap in
            if let first = sidebarSelection.first, case .actor(let name) = first,
               let resolved = newAkaMap[name], resolved != name {
                sidebarSelection = [.actor(resolved)]
            }
        }
        .onChange(of: sidebarSelection) { _, newSelection in
            if let first = newSelection.first {
                switch first {
                case .actor(let name):
                    if let resolved = akaMap[name], resolved != name {
                        DispatchQueue.main.async {
                            sidebarSelection = [.actor(resolved)]
                        }
                    }
                case .smartCollection(let id, _):
                    loadSmartCollection(id: id)
                case .allAssets:
                    filterCriteria = defaultFilterCriteria
                default:
                    break
                }
            }
        }
        .onChange(of: pendingFilter) { _, newValue in
            if let newFilter = newValue {
                filterCriteria = newFilter
                pendingFilter = nil
            }
        }
        .onChange(of: pendingSort) { _, newValue in
            if let newSort = newValue {
                sortOption = newSort
                pendingSort = nil
            }
        }
        .onChange(of: pendingSortAscending) { _, newValue in
            if let newAsc = newValue {
                sortAscending = newAsc
                pendingSortAscending = nil
            }
        }
        .onAppear {
            var handledBySidebar = false
            if let first = sidebarSelection.first {
                switch first {
                case .smartCollection(let id, _):
                    loadSmartCollection(id: id)
                    handledBySidebar = true
                case .allAssets:
                    filterCriteria = defaultFilterCriteria
                    handledBySidebar = true
                default:
                    break
                }
            }
            if !hasLoadedDefaults {
                if !handledBySidebar {
                    filterCriteria = defaultFilterCriteria
                }
                // Viewing a single series defaults to episode order.
                if isSingleSeriesSelected {
                    sortOption = .seriesOrder
                }
                hasLoadedDefaults = true
            }
            if let newFilter = pendingFilter {
                filterCriteria = newFilter
                pendingFilter = nil
            }
            if let newSort = pendingSort {
                sortOption = newSort
                pendingSort = nil
            }
            if let newAsc = pendingSortAscending {
                sortAscending = newAsc
                pendingSortAscending = nil
            }
            // Seed the cache; subsequent updates are driven by onChange.
            recomputeDisplayedAssets()
        }
    }

    // MARK: - Body
    var body: some View {
        stateManagedContent
#if os(macOS)
        // Escape clears the current video selection. Hidden button rather
        // than onExitCommand: the shortcut works regardless of which child
        // view currently has focus.
        .background(
            Button("") { selectedAssetIDs.removeAll() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        )
#endif
        .navigationTitle(sidebarSelectionTitle)
        .navigationSubtitle(isFiltered && resultViewMode == .actors ? "\(matchingActors.count) actors" : "\(displayedAssets.count) items")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search title, actor, tag, studio, notes…")
        .onAppear {
            debouncedSearchText = searchText
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
            }
        }
        .onChange(of: filterInputs) { _, _ in
            if !isFiltered { resultViewMode = .assets }
        }
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
                    
                    if !filterCriteria.isEmpty {
                        Button(action: { isShowingSaveCollection = true }) {
                            Label("Save Collection", systemImage: "folder.badge.plus")
                        }
                    }

                    Menu {
                        Picker("Preview", selection: $gridStyle) {
                            Label("Poster frame", systemImage: "photo").tag(GridStyle.singleFrame)
                            Label("Contact sheet", systemImage: "square.grid.3x3").tag(GridStyle.contactSheet)
                        }
                        Divider()
                        Picker("Columns", selection: $gridColumnCount) {
                            Text("Auto").tag(0)
                            Text("1 per row").tag(1)
                            Text("2 per row").tag(2)
                            Text("3 per row").tag(3)
                        }
                        Divider()
                        Button(action: { isShowingHelp = true }) {
                            Label("Help", systemImage: "questionmark.circle")
                        }
                    } label: {
                        Label("View Options", systemImage: "square.grid.2x2")
                    }
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
            FilterBuilderView(assets: assets, criteria: $filterCriteria, actorProfiles: entityProfiles)
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: currentHelpTopicID)
        }
        .alert("Save Smart Collection", isPresented: $isShowingSaveCollection) {
            TextField("Collection Name", text: $newCollectionName)
            Button("Cancel", role: .cancel) { newCollectionName = "" }
            Button("Save") {
                saveSmartCollection()
            }
        } message: {
            Text("Enter a name for this smart collection.")
        }
        // File sizes are only used for size-sorting. Reading attributes for
        // the whole library on the main actor stalls the UI (badly on
        // network/USB volumes), so only load when size sort is active and do
        // the I/O off the main thread.
        .task(id: FileSizeTrigger(assetCount: assets.count, sortBySize: sortOption == .size)) {
            guard sortOption == .size, !assets.isEmpty, let url = libraryURL else { return }
            let paths: [(Asset.ID, String)] = assets.map {
                ($0.id, url.appendingPathComponent($0.relativePath).path)
            }
            let newSizes = await Task.detached(priority: .utility) {
                var sizes: [Asset.ID: Int64] = [:]
                for (id, path) in paths {
                    if let attr = try? FileManager.default.attributesOfItem(atPath: path),
                       let size = attr[.size] as? Int64 {
                        sizes[id] = size
                    }
                }
                return sizes
            }.value
            fileSizes = newSizes
        }
    }
    
    // MARK: - Sub-Expressions (Helpers to fix compiler error)
    private func loadSmartCollection(id: String) {
        if let url = libraryURL {
            do {
                let store = try LibraryStore(at: url)
                let smartCollections = try store.fetchAllSmartCollections()
                if let sc = smartCollections.first(where: { $0.id == id }) {
                    if let criteria = try? JSONDecoder().decode(AssetFilterCriteria.self, from: sc.filterData) {
                        self.filterCriteria = criteria
                    }
                }
            } catch {
                print("Failed to load smart collection: \(error)")
            }
        }
    }
    
    private func mappedActors(for asset: Asset) -> Set<String> {
        return Set(asset.actors.map { akaMap[$0] ?? $0 })
    }

    // MARK: - Actors search-result mode

    // True whenever the grid is showing something narrower than the full,
    // unfiltered library — a text search, an advanced filter, or a sidebar
    // selection like a tag/actor/studio/series. That's when switching to the
    // Actors view is meaningful.
    private var isFiltered: Bool {
        if !searchText.isEmpty { return true }
        if !filterCriteria.isEmpty { return true }
        if sidebarSelection.isEmpty || sidebarSelection == [.allAssets] { return false }
        return true
    }

    private var matchingActors: [String] {
        Set(displayedAssets.flatMap { mappedActors(for: $0) }).sorted()
    }

    private func matchingActorsCount(for actor: String) -> Int {
        displayedAssets.filter { mappedActors(for: $0).contains(actor) }.count
    }

    @ViewBuilder
    private func actorNavigationWrapper<Content: View>(
        for actor: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesStackNavigation {
            NavigationLink(value: AppRoute.entityProfile(category: "actor", name: actor)) {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
                .onTapGesture {
                    var newSelection = sidebarSelection
                    newSelection.remove(.allAssets)
                    newSelection.insert(.actor(actor))
                    sidebarSelection = newSelection
                    selectedAssetIDs.removeAll()
                }
        }
    }

    private var isSingleSeriesSelected: Bool {
        guard sidebarSelection.count == 1, let first = sidebarSelection.first else { return false }
        if case .series = first { return true }
        return false
    }

    // This view is reused as the actor/studio/tag/series profile page
    // (via EntityProfileRouteView), so point Help at the right topic
    // depending on what's actually being shown.
    private var currentHelpTopicID: String {
        if sidebarSelection.count == 1, let first = sidebarSelection.first {
            switch first {
            case .actor, .studio, .tag, .series:
                return HelpContent.actorProfile.id
            default:
                break
            }
        }
        return HelpContent.allAssets.id
    }

    // MARK: - Season grouping

    private struct SeasonSection: Identifiable {
        let season: Int
        let assets: [Asset]
        var id: Int { season }
    }

    // A missing season number is treated as Season 1.
    private func effectiveSeason(_ asset: Asset) -> Int { asset.seasonNumber ?? 1 }

    /// Split the (already series-ordered) assets into contiguous season groups.
    private var seasonSections: [SeasonSection] {
        var sections: [SeasonSection] = []
        var currentSeason: Int? = nil
        var bucket: [Asset] = []
        for asset in displayedAssets {
            let season = effectiveSeason(asset)
            if currentSeason == nil {
                currentSeason = season
                bucket = [asset]
            } else if currentSeason == season {
                bucket.append(asset)
            } else {
                sections.append(SeasonSection(season: currentSeason!, assets: bucket))
                currentSeason = season
                bucket = [asset]
            }
        }
        if let s = currentSeason, !bucket.isEmpty {
            sections.append(SeasonSection(season: s, assets: bucket))
        }
        return sections
    }

    /// Group into season sections only when it adds value: a single series,
    /// sorted by Series Order, with more than one distinct season present.
    private var showSeasonSections: Bool {
        guard isSingleSeriesSelected, sortOption == .seriesOrder else { return false }
        return Set(displayedAssets.map(effectiveSeason)).count > 1
    }

    private func seasonLabel(_ season: Int) -> String {
        "Season \(season)"
    }

    // 0 = auto (fit by width); 1/2/3 = fixed column count. Persisted.
    @AppStorage("assetGridColumns") private var gridColumnCount: Int = 0

    private var gridColumns: [GridItem] {
        if gridColumnCount <= 0 {
            return [GridItem(.adaptive(minimum: 180), spacing: 16)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: gridColumnCount)
    }

    // MARK: - Search

    /// Every asset must match all whitespace-separated search terms; each term
    /// may match any searchable field (filename, series/episode, notes,
    /// actors, tags, studios, and each actor's bio and AKAs).
    private func matchesSearch(_ asset: Asset, query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = searchableStrings(for: asset)
        return terms.allSatisfy { term in
            haystack.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    private func searchableStrings(for asset: Asset) -> [String] {
        var strings: [String] = [asset.fileName]
        if let videoName = asset.videoName { strings.append(videoName) }
        if let episode = asset.episode { strings.append(episode) }
        if let notes = asset.notes { strings.append(notes) }
        strings.append(contentsOf: asset.actors)
        strings.append(contentsOf: asset.actions)
        strings.append(contentsOf: asset.studios)
        for actor in mappedActors(for: asset) {
            if let profile = entityProfiles["actor:\(actor)"] {
                if let bio = profile.bio { strings.append(bio) }
                strings.append(contentsOf: profile.akas)
            }
        }
        return strings
    }

    
    private func sidebarSelectionTitle(for item: SidebarItem) -> String {
        switch item {
        case .dashboard: return "Dashboard"
        case .allAssets: return "All"
        case .actorGallery: return "Actors Gallery"
        case .tagGallery: return "Tags Gallery"
        case .seriesGallery: return "Series Gallery"
        case .actor(let name): return name
        case .tag(let name): return name
        case .studio(let name): return name
        case .series(let name): return name
        case .smartCollection(_, let name): return name
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
        let title = debouncedSearchText.isEmpty ? "No Assets Found" : "No Results for \"\(debouncedSearchText)\""
        let symbol = debouncedSearchText.isEmpty ? "film" : "magnifyingglass"
        ContentUnavailableView(title, systemImage: symbol)
    }
    
    @ViewBuilder
    private func interactiveGridItem(for asset: Asset) -> some View {
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
        } else if !usesStackNavigation {
            Button(action: {
                selectedAssetIDs = [asset.id]
            }) {
                gridItem(for: asset)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.asset(asset.id, context: filteredAssetContext)) {
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
    
    @ViewBuilder
    private func gridItem(for asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if gridStyle == .singleFrame {
                    VideoThumbnailView(asset: asset, libraryURL: libraryURL, refreshToken: refreshID)
                } else {
                    ContactSheetThumbnailView(asset: asset, libraryURL: libraryURL, refreshToken: refreshID)
                }
            }
            .overlay(statusOverlay(for: asset), alignment: .topTrailing)
            .overlay(episodeBadge(for: asset), alignment: .topLeading)

            Text(gridLabel(for: asset))
                .font(.caption)
                .lineLimit(isSingleSeriesSelected ? 2 : 1)
                .foregroundStyle(.primary)
        }
        // Fill the column and left-align so every card is the same width — the
        // title wraps within the card and the image can't be pushed off-center
        // by a title wider than the thumbnail.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .background(selectedAssetIDs.contains(asset.id) ? Color.blue.opacity(0.15) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
    
    
    // Episode-number badge, shown only within a single-series view so it does
    // not clutter the All Assets grid.
    @ViewBuilder
    private func episodeBadge(for asset: Asset) -> some View {
        if isSingleSeriesSelected, let ep = asset.episodeNumber {
            Text("E\(ep)")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.primary)
                .padding(6)
        }
    }

    // Within a series, prefer the episode title so that metadata is visible;
    // otherwise fall back to the filename.
    private func gridLabel(for asset: Asset) -> String {
        if isSingleSeriesSelected,
           let title = asset.episode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return asset.fileName
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
    
    
    private func saveSmartCollection() {
        guard let url = libraryURL, !newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            var filterToSave = filterCriteria
            for item in sidebarSelection {
                switch item {
                case .tag(let name): filterToSave.selectedTags.insert(name)
                case .actor(let name): filterToSave.selectedActors.insert(name)
                case .studio(let name): filterToSave.selectedStudios.insert(name)
                default: break
                }
            }
            
            let data = try JSONEncoder().encode(filterToSave)
            let sc = SmartCollection(name: newCollectionName.trimmingCharacters(in: .whitespaces), filterData: data)
            let store = try LibraryStore(at: url)
            try store.saveSmartCollection(sc)
            NotificationCenter.default.post(name: NSNotification.Name("ReloadSmartCollections"), object: nil)
            newCollectionName = ""
        } catch {
            print("Failed to save smart collection: \(error)")
        }
    }
}
