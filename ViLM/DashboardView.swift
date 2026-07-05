import SwiftUI
import LibraryCore
import Charts

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
    
    @Binding var pendingAssetFilter: AssetFilterCriteria?
    @Binding var pendingAssetSort: AssetsGridView.SortOption?
    @Binding var pendingAssetSortAscending: Bool?
    @Binding var pendingActorFilter: ActorFilterCriteria?
    
    @State private var actorProfiles: [String: EntityProfile] = [:]
    @State private var profileImageFileNames: Set<String> = []
    
    private var totalActors: Int {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }
        return Set(actorTags).union(actorProfiles.keys).count
    }
    
    private var totalTags: Int {
        let allTags = assets.flatMap { $0.tags }
        let regularTags = allTags.filter { $0.hasPrefix("tag:") }
        return Set(regularTags).count
    }
    
    private var recentlyAdded: [Asset] {
        Array(assets.sorted { $0.createdAt > $1.createdAt }.prefix(10))
    }
    
    private var unreviewed: [Asset] {
        Array(assets.filter { $0.status == .unreviewed }.prefix(10))
    }
    
    private var recentlyAddedActors: [String] {
        let sortedProfiles = actorProfiles.values.sorted { 
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        return Array(sortedProfiles.prefix(10)).map { String($0.id.dropFirst(6)) }
    }
    
    private var actorsNeedingAttention: [String] {
        var needsAttention: [String] = []
        for profile in actorProfiles.values {
            let actorName = String(profile.id.dropFirst(6))
            let safeId = profile.id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
            let exactMatch = profileImageFileNames.contains("\(safeId).jpg")
            let prefixMatch = profileImageFileNames.contains { $0.hasPrefix("\(safeId)_") }
            let hasLocalPhoto = exactMatch || prefixMatch
            let hasPhoto = hasLocalPhoto || profile.photoUrl != nil
            
            if !hasPhoto {
                needsAttention.append(actorName)
            }
            if needsAttention.count >= 10 { break } // limit to 10
        }
        return needsAttention
    }
    
    private var growthData: [(date: Date, count: Int)] {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        var countsByDay: [Date: Int] = [:]
        
        for asset in assets {
            if asset.createdAt >= thirtyDaysAgo {
                let startOfDay = Calendar.current.startOfDay(for: asset.createdAt)
                countsByDay[startOfDay, default: 0] += 1
            }
        }
        
        var cumulative = 0
        var result: [(Date, Int)] = []
        for i in 0...30 {
            let day = Calendar.current.date(byAdding: .day, value: i, to: thirtyDaysAgo)!
            let startOfDay = Calendar.current.startOfDay(for: day)
            cumulative += countsByDay[startOfDay] ?? 0
            result.append((startOfDay, cumulative))
        }
        
        return result
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
                        .foregroundColor(.secondary)
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
                        Spacer()
                        Text("Last 30 days")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("+\(data.last?.count ?? 0) added")
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.accentColor)
                        Spacer()
                        Text("Today")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
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
                                VideoThumbnailCard(asset: asset, libraryURL: libraryURL)
                                    .onTapGesture {
                                        #if os(iOS)
                                        // Handle iOS navigation if needed
                                        #else
                                        selectedAssetIDs = [asset.id]
                                        #endif
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
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(18)
                        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                        .padding(.horizontal)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(unreviewed) { asset in
                                    UnreviewedVideoCard(asset: asset, libraryURL: libraryURL) {
                                        markAsReviewed(asset)
                                    }
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
                                ActorCircleCard(
                                    actorName: actor,
                                    profile: actorProfiles["actor:\(actor)"],
                                    profileImageFileNames: profileImageFileNames,
                                    libraryURL: libraryURL
                                )
                                .onTapGesture {
                                    sidebarSelection = [.actor(actor)]
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
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(18)
                        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                        .padding(.horizontal)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(actorsNeedingAttention, id: \.self) { actor in
                                ActorAttentionRow(
                                    actorName: actor,
                                    profile: actorProfiles["actor:\(actor)"],
                                    profileImageFileNames: profileImageFileNames,
                                    libraryURL: libraryURL
                                )
                                .onTapGesture {
                                    sidebarSelection = [.actor(actor)]
                                }
                                if actor != actorsNeedingAttention.last {
                                    Divider().padding(.leading, 68)
                                }
                            }
                        }
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(18)
                        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                        .padding(.horizontal)
                    }
                }
                
                Spacer().frame(height: 40)
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationBarHidden(true)
        .onAppear {
            loadActorProfiles()
            loadProfileImages()
        }
    }
    
    private func markAsReviewed(_ asset: Asset) {
        var updated = asset
        updated.status = .reviewed
        if let url = libraryURL {
            do {
                let store = try LibraryStore(at: url)
                try store.saveAsset(updated)
                NotificationCenter.default.post(name: NSNotification.Name("RefreshLibraryNotification"), object: nil)
            } catch {
                print("Failed to save asset: \(error)")
            }
        }
    }
    
    private func loadActorProfiles() {
        if let url = libraryURL {
            do {
                let store = try LibraryStore(at: url)
                let profiles = try store.fetchAllEntityProfiles()
                var dict: [String: EntityProfile] = [:]
                for p in profiles {
                    dict[p.id] = p
                }
                actorProfiles = dict
            } catch {
                print("Failed to load profiles: \(error)")
            }
        }
    }
    
    private func loadProfileImages() {
        guard let url = libraryURL else { return }
        let profilesDir = url.appendingPathComponent(".catalog/profiles")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path) {
            profileImageFileNames = Set(contents)
        }
    }
}

struct StatCardView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.title3)
                .bold()
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
    }
}

struct VideoThumbnailCard: View {
    let asset: Asset
    let libraryURL: URL?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VideoThumbnailView(asset: asset, libraryURL: libraryURL)
                .frame(width: 160, height: 90)
                .cornerRadius(12)
            
            Text(asset.fileName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
    }
}

struct UnreviewedVideoCard: View {
    let asset: Asset
    let libraryURL: URL?
    let onMarkReviewed: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                VideoThumbnailView(asset: asset, libraryURL: libraryURL)
                    .frame(width: 160, height: 90)
                    .cornerRadius(12)
                
                Text("NEW")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .cornerRadius(8)
                    .padding([.top, .leading], 6)
            }
            
            Text(asset.fileName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
            
            HStack {
                Spacer()
                Button(action: onMarkReviewed) {
                    Text("Mark Reviewed")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .frame(width: 160)
        }
    }
}

struct ActorCircleCard: View {
    let actorName: String
    let profile: EntityProfile?
    let profileImageFileNames: Set<String>
    let libraryURL: URL?
    
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = getProfileImage() {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        Text(actorName.prefix(1).uppercased())
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            
            Text(actorName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(width: 78)
            
            if let date = profile?.createdAt {
                Text(timeAgo(since: date))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func getProfileImage() -> PlatformImage? {
        guard let url = libraryURL else { return nil }
        let safeId = "actor:\(actorName)".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = url.appendingPathComponent(".catalog/profiles")
        let exactMatch = "\(safeId).jpg"
        let prefixMatch = "\(safeId)_"
        
        var targetFile: String?
        if profileImageFileNames.contains(exactMatch) {
            targetFile = exactMatch
        } else if let match = profileImageFileNames.first(where: { $0.hasPrefix(prefixMatch) }) {
            targetFile = match
        }
        
        if let target = targetFile {
            let fileURL = profilesDir.appendingPathComponent(target)
            if let data = try? Data(contentsOf: fileURL) {
                return PlatformImage(data: data)
            }
        }
        return nil
    }
    
    private func timeAgo(since date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ActorAttentionRow: View {
    let actorName: String
    let profile: EntityProfile?
    let profileImageFileNames: Set<String>
    let libraryURL: URL?
    
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = getProfileImage() {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        Text(actorName.prefix(1).uppercased())
                            .font(.headline)
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 2) {
                Text(actorName)
                    .font(.system(size: 14, weight: .semibold))
                Text(missingLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(actionLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(14)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemBackground))
    }
    
    private var hasPhoto: Bool {
        getProfileImage() != nil
    }
    
    private var hasBio: Bool {
        !(profile?.bio ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private var hasTags: Bool {
        !(profile?.tags ?? []).isEmpty
    }
    
    private var missingLabel: String {
        return "No profile photo"
    }
    
    private var actionLabel: String {
        return "Add Photo"
    }
    private func getProfileImage() -> PlatformImage? {
        guard let url = libraryURL else { return nil }
        let safeId = "actor:\(actorName)".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = url.appendingPathComponent(".catalog/profiles")
        let exactMatch = "\(safeId).jpg"
        let prefixMatch = "\(safeId)_"
        
        var targetFile: String?
        if profileImageFileNames.contains(exactMatch) {
            targetFile = exactMatch
        } else if let match = profileImageFileNames.first(where: { $0.hasPrefix(prefixMatch) }) {
            targetFile = match
        }
        
        if let target = targetFile {
            let fileURL = profilesDir.appendingPathComponent(target)
            if let data = try? Data(contentsOf: fileURL) {
                return PlatformImage(data: data)
            }
        }
        return nil
    }
}
