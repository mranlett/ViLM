// DashboardView.swift
// The home dashboard: hero stats, 30-day library growth chart, the Smart
// Shelves (live metadata-driven accordion rows — Recently Added, Never Watched,
// Top Rated, Rediscover, Most Watched), recently added actors, and the Actors
// Needing Attention list. Derived stats + shelf previews are cached and
// recomputed only when the underlying data changes.

import SwiftUI
import LibraryCore
import Charts
import ImageIO

struct DashboardView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    @Binding var selectedAssetIDs: Set<Asset.ID>
    
    let libraryURL: URL?

    // Loaded once at the ContentView level and shared across every screen
    // that needs actor profiles, instead of each screen independently
    // re-fetching the same data on its own `.onAppear`.
    let entityProfiles: [String: EntityProfile]
    let profileImageFileNames: Set<String>
    let akaMap: [String: String]

    @Binding var pendingAssetFilter: AssetFilterCriteria?
    @Binding var pendingAssetSort: AssetsGridView.SortOption?
    @Binding var pendingAssetSortAscending: Bool?
    @Binding var pendingActorFilter: ActorFilterCriteria?

    /// Opens a Smart Shelf's full "See All" list (pushed by ContentView).
    let onSeeAllShelf: (LibraryQuery) -> Void
    /// Runs a quick action in-app (the same actions as the Home Screen menu).
    let onQuickAction: (QuickAction) -> Void
    /// Saved Smart Collections, surfaced as Dashboard accordions (v2).
    let smartCollections: [SmartCollection]

    private var actorProfiles: [String: EntityProfile] {
        entityProfiles.filter { $0.key.hasPrefix("actor:") }
    }

    @Environment(\.usesStackNavigation) private var usesStackNavigation

    // Cached derived stats. Recomputed only when assets or the loaded
    // profiles/images change, rather than re-sorting/re-bucketing the whole
    // library on every render of the dashboard.
    @State private var totalActors: Int = 0
    @State private var totalTags: Int = 0
    @State private var shelfPreviews: [LibraryQuery: [Asset]] = [:]
    @State private var shelfCounts: [LibraryQuery: Int] = [:]
    @State private var recentlyAddedActors: [String] = []
    @State private var actorsNeedingAttention: [String] = []
    @State private var growthData: [(date: Date, count: Int)] = []
    @State private var isShowingHelp = false

    // Smart Shelves render as accordions, collapsed by default; which ones are
    // expanded persists across launches. Order per the Smart Shelves spec.
    @AppStorage("dashboardExpandedShelves") private var expandedShelvesRaw: String = ""
    private let shelfOrder: [LibraryQuery] = [.recentlyAdded, .neverWatched, .topRated, .rediscover, .mostWatched]
    private static let shelfPreviewCount = 10

    // Smart Collections (v2): same accordion treatment, keyed by collection id.
    @State private var collectionPreviews: [String: [Asset]] = [:]
    @State private var collectionCounts: [String: Int] = [:]
    @AppStorage("dashboardExpandedCollections") private var expandedCollectionsRaw: String = ""

    private func recomputeStats() {
        // Filtered once here rather than read through the computed
        // `actorProfiles` property below, which would otherwise re-filter
        // the full entityProfiles dict on every single access in the loops
        // that follow.
        let actorProfiles = self.actorProfiles

        var actorNameSet = Set<String>()
        var tagSet = Set<String>()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        var countsByDay: [Date: Int] = [:]

        for asset in assets {
            for tag in asset.tags {
                if tag.hasPrefix("actor:") {
                    let rawName = String(tag.dropFirst(6))
                    actorNameSet.insert(akaMap[rawName] ?? rawName)
                } else if tag.hasPrefix("tag:") {
                    tagSet.insert(tag)
                }
            }
            if asset.createdAt >= thirtyDaysAgo {
                let startOfDay = Calendar.current.startOfDay(for: asset.createdAt)
                countsByDay[startOfDay, default: 0] += 1
            }
        }
        // Actors with a saved profile but 0 matched videos still count.
        for key in actorProfiles.keys {
            actorNameSet.insert(String(key.dropFirst(6)))
        }

        totalActors = actorNameSet.count
        totalTags = tagSet.count

        // Smart Shelves: compute each pool once here (cheap sorts/filters over
        // the assets array), caching the preview strip + total count. Recomputed
        // on the same triggers as the rest of the dashboard (assets/profiles
        // change → "ReloadAssets").
        var previews: [LibraryQuery: [Asset]] = [:]
        var counts: [LibraryQuery: Int] = [:]
        for query in LibraryQuery.allCases {
            let full = query.run(assets: assets)
            counts[query] = full.count
            previews[query] = Array(full.prefix(Self.shelfPreviewCount))
        }
        shelfPreviews = previews
        shelfCounts = counts

        // Smart Collections: each collection's contents are the assets matching
        // its saved AssetFilterCriteria (the same shared matcher the All Assets
        // grid uses when a collection is selected).
        var collPreviews: [String: [Asset]] = [:]
        var collCounts: [String: Int] = [:]
        for collection in smartCollections {
            guard let criteria = try? JSONDecoder().decode(AssetFilterCriteria.self, from: collection.filterData) else { continue }
            let matched = assets.filter { asset in
                criteria.matches(asset,
                                 mappedActors: AssetFilterCriteria.mappedActors(for: asset, akaMap: akaMap),
                                 entityProfiles: entityProfiles)
            }
            collCounts[collection.id] = matched.count
            collPreviews[collection.id] = Array(matched
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(Self.shelfPreviewCount))
        }
        collectionPreviews = collPreviews
        collectionCounts = collCounts

        let sortedProfiles = actorProfiles.values.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        recentlyAddedActors = Array(sortedProfiles.prefix(10)).map { String($0.id.dropFirst(6)) }

        // Every actor ever referenced, not just those with a saved profile —
        // an actor with no profile at all necessarily has no photo, so
        // skipping them here (as this used to) silently hid exactly the
        // actors most in need of attention.
        var needsAttention: [String] = []
        for name in actorNameSet.sorted() {
            let profile = actorProfiles["actor:\(name)"]
            let safeId = "actor:\(name)".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
            let hasLocalPhoto = profileImageFileNames.contains("\(safeId).jpg")
                || profileImageFileNames.contains { $0.hasPrefix("\(safeId)_") }
            let hasPhoto = hasLocalPhoto || profile?.photoUrl != nil
            if !hasPhoto {
                needsAttention.append(name)
            }
            if needsAttention.count >= 10 { break }
        }
        actorsNeedingAttention = needsAttention

        var cumulative = 0
        var result: [(date: Date, count: Int)] = []
        for i in 0...30 {
            let day = Calendar.current.date(byAdding: .day, value: i, to: thirtyDaysAgo)!
            let startOfDay = Calendar.current.startOfDay(for: day)
            cumulative += countsByDay[startOfDay] ?? 0
            result.append((startOfDay, cumulative))
        }
        growthData = result
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library")
                        .font(.largeTitle)
                        .bold()
                    Text("Here's what's new in your library")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                // Hero stat cards
                HStack(spacing: 12) {
                    StatCardView(title: "Videos", value: "\(assets.count)")
                    StatCardView(title: "Actors", value: "\(totalActors)")
                    StatCardView(title: "Tags", value: "\(totalTags)")
                }
                .padding(.horizontal)
                
                // Library Growth Chart
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Library Growth")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("Last 30 days")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    
                    let data = growthData
                    Chart {
                        ForEach(data, id: \.date) { item in
                            LineMark(
                                x: .value("Date", item.date),
                                y: .value("Added", item.count)
                            )
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.catmullRom)
                            
                            AreaMark(
                                x: .value("Date", item.date),
                                y: .value("Added", item.count)
                            )
                            .foregroundStyle(LinearGradient(
                                colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .frame(height: 120)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    
                    HStack {
                        Text("30d ago")
                            .font(.caption2)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("+\(data.last?.count ?? 0) added")
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.accentColor)
                        Spacer()
                        Text("Today")
                            .font(.caption2)
                            .foregroundColor(.primary)
                    }
                }
                .padding()
                .background(Color(PlatformSystemBackground))
                .cornerRadius(18)
                .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                .padding(.horizontal)
                
                // Smart Shelves — live, metadata-driven rows (accordion,
                // collapsed by default).
                smartShelvesSection

                // Saved Smart Collections, below the auto-generated shelves.
                smartCollectionsSection

                recentlyAddedActorsSection

                actorsNeedingAttentionSection

                Spacer().frame(height: 40)
            }
        }
        .background(Color(PlatformSystemGroupedBackground))
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { isShowingHelp = true }) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help")
                .accessibilityLabel("Help")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(QuickAction.allCases, id: \.self) { action in
                        Button {
                            onQuickAction(action)
                        } label: {
                            Label(action.menuTitle, systemImage: action.menuIcon)
                        }
                    }
                } label: {
                    Image(systemName: "shuffle")
                }
                .help("Shuffle — surface something to watch")
                .accessibilityLabel("Shuffle")
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: HelpContent.dashboard.id)
        }
        .onAppear {
            recomputeStats()
        }
        .onChange(of: assets) { _, _ in
            recomputeStats()
        }
        .onChange(of: entityProfiles) { _, _ in
            recomputeStats()
        }
        .onChange(of: smartCollections) { _, _ in
            recomputeStats()
        }
    }
    
    // MARK: - Actor sections (extracted to keep the body type-checkable)

    private var recentlyAddedActorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recently Added Actors").font(.title3).bold()
                Spacer()
                Button("See All") {
                    var criteria = ActorFilterCriteria()
                    criteria.sortBy = .dateAdded
                    criteria.sortDescending = true
                    pendingActorFilter = criteria
                    sidebarSelection = [.actorGallery]
                }
                .font(.subheadline).bold()
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(recentlyAddedActors, id: \.self) { actor in
                        actorNavigationWrapper(for: actor) {
                            ActorCircleCard(
                                actorName: actor,
                                profile: actorProfiles["actor:\(actor)"],
                                profileImageFileNames: profileImageFileNames,
                                libraryURL: libraryURL)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var actorsNeedingAttentionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Actors Needing Attention").font(.title3).bold()
                Spacer()
                if !actorsNeedingAttention.isEmpty {
                    Button("See All") {
                        var criteria = ActorFilterCriteria()
                        criteria.showNeedingAttentionOnly = true
                        pendingActorFilter = criteria
                        sidebarSelection = [.actorGallery]
                    }
                    .font(.subheadline).bold()
                }
            }
            .padding(.horizontal)

            if actorsNeedingAttention.isEmpty {
                VStack(spacing: 6) {
                    Text("✅").font(.largeTitle)
                    Text("All profiles complete").font(.headline)
                    Text("Every actor has a profile photo.").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(Color(PlatformSystemBackground))
                .cornerRadius(18)
                .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(actorsNeedingAttention, id: \.self) { actor in
                        actorNavigationWrapper(for: actor) {
                            ActorAttentionRow(
                                actorName: actor,
                                profile: actorProfiles["actor:\(actor)"],
                                profileImageFileNames: profileImageFileNames,
                                libraryURL: libraryURL)
                        }
                        if actor != actorsNeedingAttention.last {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .background(Color(PlatformSystemBackground))
                .cornerRadius(18)
                .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Smart Shelves + Collections (accordions)

    private var smartShelvesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(shelfOrder, id: \.self) { query in
                accordionStrip(
                    title: query.title,
                    count: shelfCounts[query] ?? 0,
                    previews: shelfPreviews[query] ?? [],
                    expanded: isShelfExpanded(query),
                    emptyText: "No videos here yet.",
                    onToggle: { toggleShelf(query) },
                    onSeeAll: { onSeeAllShelf(query) })
            }
        }
    }

    @ViewBuilder
    private var smartCollectionsSection: some View {
        if !smartCollections.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("Smart Collections")
                    .font(.headline).foregroundColor(.secondary)
                    .padding(.horizontal)
                ForEach(smartCollections) { sc in
                    accordionStrip(
                        title: sc.name,
                        count: collectionCounts[sc.id] ?? 0,
                        previews: collectionPreviews[sc.id] ?? [],
                        expanded: isCollectionExpanded(sc.id),
                        emptyText: "Nothing matches this collection right now.",
                        onToggle: { toggleCollection(sc.id) },
                        onSeeAll: { sidebarSelection = [.smartCollection(sc.id, sc.name)] })
                    .contextMenu {
                        Button(role: .destructive) {
                            NotificationCenter.default.post(name: NSNotification.Name("DeleteSmartCollection"), object: sc.id)
                        } label: {
                            Label("Delete Collection", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // Shared accordion row used by both metadata shelves and saved collections:
    // collapsed header (title + count + chevron), expanded preview strip + See All.
    @ViewBuilder
    private func accordionStrip(
        title: String, count: Int, previews: [Asset], expanded: Bool,
        emptyText: String, onToggle: @escaping () -> Void, onSeeAll: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { onToggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title).font(.title3).bold().foregroundColor(.primary)
                    Text("\(count)")
                        .font(.subheadline).bold().foregroundColor(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityLabel("\(title), \(count) videos, \(expanded ? "expanded" : "collapsed")")

            if expanded {
                if previews.isEmpty {
                    Text(emptyText)
                        .font(.callout).foregroundColor(.secondary)
                        .padding(.horizontal).padding(.vertical, 6)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(previews) { asset in
                                videoNavigationWrapper(for: asset, context: previews.map(\.id)) {
                                    VideoThumbnailCard(asset: asset, libraryURL: libraryURL)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    if count > previews.count {
                        Button("See All (\(count))") { onSeeAll() }
                            .font(.subheadline).bold().padding(.horizontal)
                    }
                }
            }
        }
    }

    private func isShelfExpanded(_ query: LibraryQuery) -> Bool {
        expandedShelvesRaw.split(separator: ",").contains(Substring(query.rawValue))
    }

    private func toggleShelf(_ query: LibraryQuery) {
        expandedShelvesRaw = toggled(query.rawValue, in: expandedShelvesRaw)
    }

    private func isCollectionExpanded(_ id: String) -> Bool {
        expandedCollectionsRaw.split(separator: ",").contains(Substring(id))
    }

    private func toggleCollection(_ id: String) {
        expandedCollectionsRaw = toggled(id, in: expandedCollectionsRaw)
    }

    private func toggled(_ key: String, in raw: String) -> String {
        var set = Set(raw.split(separator: ",").map(String.init))
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        return set.sorted().joined(separator: ",")
    }

    // MARK: - Navigation helpers
    //
    // Compact width (iPhone): cards are real NavigationLinks that push onto
    // the enclosing stack. Regular width (iPad/macOS): cards select into the
    // detail pane, matching the split-view layout.

    @ViewBuilder
    private func videoNavigationWrapper<Content: View>(
        for asset: Asset,
        context: [Asset.ID],
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesStackNavigation {
            NavigationLink(value: AppRoute.asset(asset.id, context: context)) {
                content()
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                selectedAssetIDs = [asset.id]
            })
        } else {
            content()
                .onTapGesture { selectedAssetIDs = [asset.id] }
        }
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
                .onTapGesture { selectActorInSidebar(actor) }
        }
    }

    private func selectActorInSidebar(_ actor: String) {
        let others = sidebarSelection.filter { if case .actor = $0 { return false }; return true }
        sidebarSelection = others.union([.actor(actor)])
        // The detail pane shows a selected video with priority over a
        // selected actor, so clear the video selection when picking an actor.
        selectedAssetIDs.removeAll()
    }

}
