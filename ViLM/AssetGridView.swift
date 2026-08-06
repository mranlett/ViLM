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
    /// Non-nil = the "New Playlist" prompt is up for these videos.
    @State private var newPlaylistPendingIDs: [Asset.ID]? = nil
    @State private var isShowingHelp = false
    let libraryURL: URL?
    let refreshID: UUID

    /// Whether this grid provides the window's search field.
    ///
    /// ⚠️ Exactly ONE view per window may declare `.searchable`. SwiftUI maps
    /// it to a toolbar item with a fixed identifier —
    /// `com.apple.SwiftUI.search` — and AppKit throws
    /// `NSInternalInconsistencyException` when a second item claims it, which
    /// crashes the app rather than degrading.
    ///
    /// Two grids are alive together whenever a profile page opens beside the
    /// browse column: selecting an actor puts one in the content column and
    /// another inside `EntityProfileRouteView` in the detail column. The
    /// embedded one therefore declines, and the browse column keeps the search
    /// field where it has always been.
    var providesSearchField: Bool = true
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
    
    /// One definition, shared with LibraryCore so the ordering rules it drives can
    /// be unit-tested (see AssetSortTests). Call sites keep saying `SortOption`.
    typealias SortOption = AssetSort.Option
    
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
    /// How many videos the persisted filter model is suppressing on this page.
    ///
    /// An empty page that says nothing is indistinguishable from a broken one —
    /// a review-status filter emptying a tag page cost hours of misdiagnosis
    /// before anyone noticed a filter was on.
    @State private var videosHiddenByFilter: Int = 0
    // Seasons the user has collapsed in the grouped series view (nil season = Int.min).
    @State private var collapsedSeasons: Set<Int> = []
    // A–Z letter strip over display titles ("#" = non-letter starts).
    @State private var alphaFilter: Character? = nil

    // Bundles the cheap-to-compare filter inputs for a single onChange.
    private struct FilterInputs: Equatable {
        let sidebarSelection: Set<SidebarItem>
        let searchText: String
        let filterCriteria: AssetFilterCriteria
        let sortOption: SortOption
        let sortAscending: Bool
        let alphaFilter: Character?
    }

    private var filterInputs: FilterInputs {
        FilterInputs(
            sidebarSelection: sidebarSelection,
            searchText: debouncedSearchText,
            filterCriteria: filterCriteria,
            sortOption: sortOption,
            sortAscending: sortAscending,
            alphaFilter: alphaFilter
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
        // Recomputed here rather than per render: this is a second pass over
        // the assets, cheap on a filter change and wrong to repeat per frame.
        videosHiddenByFilter = filterCriteria.isEmpty
            ? 0
            : max(0, computeFilteredAssets(applyingCriteria: false).count - displayedAssets.count)
    }

    /// - Parameter applyingCriteria: pass `false` to skip the persisted filter
    ///   model and get what this page WOULD show without it. Used to report how
    ///   many items a filter is hiding, so an empty page is never silent.
    private func computeFilteredAssets(applyingCriteria: Bool = true) -> [Asset] {
        let filtered = assets.filter { asset in
            let matchesCategory = sidebarSelection.isEmpty ? true : sidebarSelection.allSatisfy { item in
                switch item {
                case .dashboard, .allAssets, .actorGallery, .tagGallery, .seriesGallery, .studioGallery, .smartCollection: return true
                case .actor(let name): return mappedActors(for: asset).contains(name)
                case .tag(let name):
                    // A tag can apply directly to a video, or only exist on
                    // an actor's own profile (e.g. "Blonde") — match either,
                    // since Tag Gallery surfaces both kinds under one name.
                    //
                    // Matched on FOLDED identity, not raw spelling. The gallery
                    // collapses two casings into one card, so an exact match
                    // here would open that card onto only the videos spelled
                    // the way its label happened to be — the rest silently
                    // missing, and the count short.
                    let wanted = TagNormalizer.identityKey(name)
                    if asset.actions.contains(where: { TagNormalizer.identityKey($0) == wanted }) {
                        return true
                    }
                    return mappedActors(for: asset).contains { actor in
                        entityProfiles["actor:\(actor)"]?.tags
                            .contains { TagNormalizer.identityKey($0) == wanted } ?? false
                    }
                case .studio(let name): return asset.tags.contains("studio:\(name)")
                case .series(let name): return asset.videoName == name
                }
            }
            
            if !matchesCategory { return false }

            // Review status, rating, and the actor/tag/studio + actor-metadata
            // sets are the persisted filter model — matched by the shared,
            // unit-tested implementation in LibraryCore so this grid and the
            // Move-Between-Libraries page stay in lockstep.
            if applyingCriteria,
               !filterCriteria.matches(asset, mappedActors: mappedActors(for: asset), entityProfiles: entityProfiles) {
                return false
            }

            if !matchesSearch(asset, query: debouncedSearchText) {
                return false
            }

            // A–Z strip: first letter of the display title; "#" catches
            // titles that don't start with a letter.
            if let letter = alphaFilter {
                let first = (asset.videoName ?? asset.fileName)
                    .trimmingCharacters(in: .whitespaces).first
                if letter == "#" {
                    if first?.isLetter == true { return false }
                } else {
                    guard let first, String(first).uppercased() == String(letter) else { return false }
                }
            }

            return true
        }
        
        // Ordering rules live in LibraryCore (AssetSort) so they can be unit-tested
        // without a view; see AssetSortTests. Behaviour is unchanged.
        return AssetSort.sorted(filtered,
                                by: sortOption,
                                ascending: sortAscending,
                                fileSizes: fileSizes)
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
        case .studioGallery: return "Studios Gallery"
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

                if videosHiddenByFilter > 0 {
                    Label {
                        Text("^[\(videosHiddenByFilter) video](inflect: true) hidden by your filters")
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
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

                // A–Z jump strip for the video grid (hidden while viewing the
                // actors result mode — it filters by video title).
                if !(isFiltered && resultViewMode == .actors) {
                    AlphaPickerView(filter: $alphaFilter)
                        .padding(.horizontal)
                        .padding(.top, 10)
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
            // The letter strip is scoped to the current browsing context.
            alphaFilter = nil
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
        .searchableIfProvided(providesSearchField, text: $searchText,
                              prompt: "Search title, actor, tag, studio, notes…")
#if os(iOS)
        // Scrolling the results collapses the keyboard (search text stays),
        // so the toolbar and bottom bar are reachable mid-search.
        .scrollDismissesKeyboard(.immediately)
#endif
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
            // The bar shows whenever selection mode is on (not only once
            // something is selected): "Select All" is the search-to-batch-edit
            // workflow — search for a name, select every result, add the
            // actor to all of them in one batch edit. It must carry its OWN
            // exit — the nav-bar Select/Done toggle is hidden while the
            // search field is active, so without "Done" here, selection mode
            // entered from a search was a trap with no way out.
            if isEditMode {
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 16) {
                        Button("Done") {
                            isEditMode = false
                            selectedAssetIDs.removeAll()
                        }
                        .fontWeight(.semibold)
                        let allSelected = !displayedAssets.isEmpty
                            && selectedAssetIDs.count == displayedAssets.count
                        Button(allSelected ? "Deselect All" : "Select All (\(displayedAssets.count))") {
                            selectedAssetIDs = allSelected ? [] : Set(displayedAssets.map(\.id))
                        }
                        .disabled(displayedAssets.isEmpty)
                        Spacer()
                        if !selectedAssetIDs.isEmpty {
                            // The search → select → add-to-playlist flow.
                            Menu {
                                AddToPlaylistMenuItems(assetIDs: Array(selectedAssetIDs)) {
                                    newPlaylistPendingIDs = Array(selectedAssetIDs)
                                }
                            } label: {
                                Label("Playlist", systemImage: "list.and.film")
                            }
                            NavigationLink(value: AppRoute.assets(selectedAssetIDs)) {
                                Text("Edit \(selectedAssetIDs.count) Selected")
                                    .font(.headline)
                            }
                        }
                    }
                }
            }
#endif
        }
        .sheet(isPresented: $isShowingFilterBuilder) {
            FilterBuilderView(assets: assets, criteria: $filterCriteria, actorProfiles: entityProfiles)
        }
        .modifier(NewPlaylistPrompt(pendingAssetIDs: $newPlaylistPendingIDs))
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
            guard sortOption == .size, !assets.isEmpty else { return }
            let paths: [(Asset.ID, String)] = assets.compactMap { asset in
                LibrarySession.shared.videoURL(for: asset).map { (asset.id, $0.path) }
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

    /// Who the Actors tab is about.
    ///
    /// The Videos tab answers "what can I watch"; this answers "who is this
    /// about". Those are the same question for a studio, a series or an actor —
    /// there the connection genuinely IS "appeared together in these videos".
    ///
    /// They are NOT the same for a TAG. A tag page shows every video in which
    /// any tagged actor appears, so deriving actors from those videos returned
    /// the whole cast of each: a blonde who happened to be in a video with a
    /// redhead was listed under "Redhead".
    ///
    /// Narrowed only for a single tag selection, using exactly the notion the
    /// ASSET filter uses above, so the two cannot disagree.
    private var matchingActors: [String] {
        guard sidebarSelection.count == 1,
              case .tag(let name)? = sidebarSelection.first else {
            // Studio, series and actor pages: the connection genuinely IS
            // "appeared together in these videos", so derive from them.
            return Set(displayedAssets.flatMap { mappedActors(for: $0) }).sorted()
        }
        // A tag page is DECOUPLED from the video list. Which actors carry a tag
        // is a property of the actors, not of which of their videos happen to
        // pass a video filter — a review-status filter used to empty this tab
        // entirely, which read as "no actors have this tag".
        //
        // Actor-side filtering is a separate axis and belongs to the actor
        // filter model, not to this one.
        // Folded, matching the asset filter above — the comment there promises
        // "exactly the notion the ASSET filter uses", and an exact match here
        // would break that promise the moment two casings exist.
        let wanted = TagNormalizer.identityKey(name)
        return entityProfiles.compactMap { key, profile -> String? in
            guard key.hasPrefix("actor:"),
                  profile.tags.contains(where: { TagNormalizer.identityKey($0) == wanted })
            else { return nil }
            return String(key.dropFirst(6))
        }.sorted()
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
        case .studioGallery: return "Studios Gallery"
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
    
#if os(iOS)
    /// Long-press menu: the in-grid path into selection mode. This must exist
    /// because the nav-bar "Select" button is HIDDEN while the search field is
    /// active on iPhone — without it, "search, then batch-edit the results"
    /// was impossible (cancelling search to reach the button clears the
    /// results).
    @ViewBuilder
    private func selectionContextMenu(for asset: Asset) -> some View {
        Button {
            isEditMode = true
            selectedAssetIDs.insert(asset.id)
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Button {
            isEditMode = true
            selectedAssetIDs = Set(displayedAssets.map(\.id))
        } label: {
            Label("Select All \(displayedAssets.count) Shown", systemImage: "checklist.checked")
        }
        Menu {
            AddToPlaylistMenuItems(assetIDs: [asset.id]) {
                newPlaylistPendingIDs = [asset.id]
            }
        } label: {
            Label("Add to Playlist", systemImage: "list.and.film")
        }
    }
#endif

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
            .contextMenu { selectionContextMenu(for: asset) }
        } else {
            NavigationLink(value: AppRoute.asset(asset.id, context: filteredAssetContext)) {
                gridItem(for: asset)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                selectedAssetIDs = [asset.id]
            })
            .contextMenu { selectionContextMenu(for: asset) }
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
        .contextMenu {
            // Right-click acts on the ⌘-click multi-selection when it
            // includes this card; otherwise just this card.
            let targets = (selectedAssetIDs.contains(asset.id) && selectedAssetIDs.count > 1)
                ? Array(selectedAssetIDs) : [asset.id]
            Menu {
                AddToPlaylistMenuItems(assetIDs: targets) {
                    newPlaylistPendingIDs = targets
                }
            } label: {
                Label(targets.count > 1 ? "Add \(targets.count) to Playlist" : "Add to Playlist",
                      systemImage: "list.and.film")
            }
        }
#endif
    }
    
    /// How old THIS actor was when the video was released.
    ///
    /// Only on an actor's own page: the figure is a property of the pairing,
    /// not of the video, so on a tag or studio page there is no single person
    /// it could be about. Absent when either date is unknown — the gap belongs
    /// on the actor's profile, not repeated under every card.
    @ViewBuilder
    private func ageAtReleasePill(for asset: Asset) -> some View {
        if let age = ageAtRelease(for: asset) {
            HStack(spacing: 3) {
                Text(age.displayText)
                // An approximate figure is marked, because a birth year cannot
                // say whether the birthday had come round yet.
                if !age.isExact { Image(systemName: "questionmark").font(.system(size: 7)) }
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.teal.opacity(0.18))
            .foregroundStyle(Color.teal)
            .clipShape(Capsule())
            .help(age.isExact ? "Age at release" : "Age at release — approximate, only a birth year is recorded")
        }
    }

    private func ageAtRelease(for asset: Asset) -> AgeAtRelease? {
        guard sidebarSelection.count == 1,
              case .actor(let name)? = sidebarSelection.first,
              let profile = entityProfiles["actor:\(name)"]
        else { return nil }
        return AgeAtReleaseCalculator.age(of: profile, at: asset.releaseDate)
    }

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

            ageAtReleasePill(for: asset)
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
