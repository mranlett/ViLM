// DashboardView.swift
// The home dashboard: hero stats, 30-day library growth chart, recently
// added / unreviewed video carousels, recently added actors, and the Actors
// Needing Attention list. Derived stats are cached and recomputed only when
// the underlying data changes.

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

    private var actorProfiles: [String: EntityProfile] {
        entityProfiles.filter { $0.key.hasPrefix("actor:") }
    }

    @Environment(\.usesStackNavigation) private var usesStackNavigation

    // Cached derived stats. Recomputed only when assets or the loaded
    // profiles/images change, rather than re-sorting/re-bucketing the whole
    // library on every render of the dashboard.
    @State private var totalActors: Int = 0
    @State private var totalTags: Int = 0
    @State private var recentlyAdded: [Asset] = []
    @State private var unreviewed: [Asset] = []
    @State private var recentlyAddedActors: [String] = []
    @State private var actorsNeedingAttention: [String] = []
    @State private var growthData: [(date: Date, count: Int)] = []
    @State private var isShowingHelp = false

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
        recentlyAdded = Array(assets.sorted { $0.createdAt > $1.createdAt }.prefix(10))
        unreviewed = Array(assets.filter { $0.status == .unreviewed }.prefix(10))

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
                
                // Recently Added
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recently Added")
                            .font(.title3)
                            .bold()
                        Spacer()
                        Button("See All") {
                            pendingAssetFilter = AssetFilterCriteria()
                            pendingAssetSort = .date
                            pendingAssetSortAscending = false
                            sidebarSelection = [.allAssets]
                        }
                        .font(.subheadline)
                        .bold()
                    }
                    .padding(.horizontal)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recentlyAdded) { asset in
                                videoNavigationWrapper(for: asset, context: recentlyAdded.map(\.id)) {
                                    VideoThumbnailCard(asset: asset, libraryURL: libraryURL)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Unreviewed Videos
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Unreviewed")
                            .font(.title3)
                            .bold()
                        Spacer()
                        if !unreviewed.isEmpty {
                            Button("See All (\(assets.filter { $0.status == .unreviewed }.count))") {
                                var criteria = AssetFilterCriteria()
                                criteria.reviewStatus = .unreviewed
                                pendingAssetFilter = criteria
                                pendingAssetSort = .date
                                pendingAssetSortAscending = false
                                sidebarSelection = [.allAssets]
                            }
                            .font(.subheadline)
                            .bold()
                        }
                    }
                    .padding(.horizontal)
                    
                    if unreviewed.isEmpty {
                        VStack(spacing: 6) {
                            Text("✅").font(.largeTitle)
                            Text("All caught up").font(.headline)
                            Text("No unreviewed videos right now.").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                        .background(Color(PlatformSystemBackground))
                        .cornerRadius(18)
                        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                        .padding(.horizontal)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(unreviewed) { asset in
                                    UnreviewedVideoCard(
                                        asset: asset,
                                        libraryURL: libraryURL,
                                        openRoute: compactRoute(for: asset, context: unreviewed.map(\.id)),
                                        onOpen: { selectedAssetIDs = [asset.id] },
                                        onMarkReviewed: { markAsReviewed(asset) }
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                
                // Recently Added Actors
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recently Added Actors")
                            .font(.title3)
                            .bold()
                        Spacer()
                        Button("See All") {
                            var criteria = ActorFilterCriteria()
                            criteria.sortBy = .dateAdded
                            criteria.sortDescending = true
                            pendingActorFilter = criteria
                            sidebarSelection = [.actorGallery]
                        }
                        .font(.subheadline)
                        .bold()
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
                                        libraryURL: libraryURL
                                    )
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Actors Needing Attention
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Actors Needing Attention")
                            .font(.title3)
                            .bold()
                        Spacer()
                        if !actorsNeedingAttention.isEmpty {
                            Button("See All") {
                                var criteria = ActorFilterCriteria()
                                criteria.showNeedingAttentionOnly = true
                                pendingActorFilter = criteria
                                sidebarSelection = [.actorGallery]
                            }
                            .font(.subheadline)
                            .bold()
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
                                        libraryURL: libraryURL
                                    )
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

    private func compactRoute(for asset: Asset, context: [Asset.ID]) -> AppRoute? {
        if usesStackNavigation {
            return .asset(asset.id, context: context)
        }
        return nil
    }

    private func markAsReviewed(_ asset: Asset) {
        var updated = asset
        updated.status = .reviewed
        if let url = libraryURL {
            do {
                let store = try LibraryStore(at: url)
                // saveAsset is insert-only (INSERT OR IGNORE); updating an
                // existing row requires updateAsset.
                try store.updateAsset(updated)
                NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
            } catch {
                print("Failed to save asset: \(error)")
                AppErrorReporter.report("Couldn't mark the video as reviewed: \(error.localizedDescription)")
            }
        }
    }
    
}
