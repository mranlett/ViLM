import SwiftUI
import LibraryCore

struct SidebarView: View {
    @Binding var selection: Set<SidebarItem>
    let assets: [Asset]
    let libraryURL: URL?
    let smartCollections: [SmartCollection]
    let onApplyFilters: () -> Void
    
    @State private var profiles: [EntityProfile] = []
    @State private var akaMap: [String: String] = [:]
    
    @State private var isSmartCollectionsExpanded = true
    @State private var isActorsExpanded = true
    @State private var isTagsExpanded = true
    @State private var isStudiosExpanded = true
    
    @State private var actorAlphaFilter: Character? = nil
    @State private var tagAlphaFilter: Character? = nil
    @State private var studioAlphaFilter: Character? = nil
    
    // MARK: - Computed Properties
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        var unique = Set(actorTags.map { akaMap[$0] ?? $0 })
        
        for profile in profiles where profile.id.hasPrefix("actor:") {
            unique.insert(String(profile.id.dropFirst(6)))
        }
        return Array(unique).sorted()
    }
    
    var allUniqueTags: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actionTags = allTags.filter { $0.hasPrefix("tag:") }.map { String($0.dropFirst(4)) }
        var unique = Set(actionTags)
        
        for profile in profiles where profile.id.hasPrefix("tag:") {
            unique.insert(String(profile.id.dropFirst(4)))
        }
        return Array(unique).sorted()
    }
    
    var allUniqueStudios: [String] {
        let allTags = assets.flatMap { $0.tags }
        let studioTags = allTags.filter { $0.hasPrefix("studio:") }.map { String($0.dropFirst(7)) }
        var unique = Set(studioTags)
        
        for profile in profiles where profile.id.hasPrefix("studio:") {
            unique.insert(String(profile.id.dropFirst(7)))
        }
        return Array(unique).sorted()
    }
    
    var actorCounts: [String: Int] {
        var counts = [String: Int]()
        for asset in assets {
            var countedForAsset = Set<String>()
            for tag in asset.tags where tag.hasPrefix("actor:") {
                let name = String(tag.dropFirst(6))
                let mapped = akaMap[name] ?? name
                countedForAsset.insert(mapped)
            }
            for mapped in countedForAsset {
                counts[mapped, default: 0] += 1
            }
        }
        return counts
    }

    var tagCounts: [String: Int] {
        var counts = [String: Int]()
        for asset in assets {
            for tag in asset.tags where tag.hasPrefix("tag:") {
                counts[String(tag.dropFirst(4)), default: 0] += 1
            }
        }
        return counts
    }

    var studioCounts: [String: Int] {
        var counts = [String: Int]()
        for asset in assets {
            for tag in asset.tags where tag.hasPrefix("studio:") {
                counts[String(tag.dropFirst(7)), default: 0] += 1
            }
        }
        return counts
    }
    
    // Stats for progress tracking
    private var reviewProgress: Double {
        guard !assets.isEmpty else { return 0 }
        let reviewed = assets.filter { $0.status == .reviewed }.count
        return Double(reviewed) / Double(assets.count)
    }

    private var unreviewedCount: Int {
        assets.filter { $0.status == .unreviewed }.count
    }
    
    // MARK: - Body
    
    var body: some View {
        List {
            Section("Library") {
                // Top-level sections navigate immediately; onApplyFilters is a
                // no-op in the split layout and pushes the content view on iPhone.
                sidebarRow(title: "Dashboard", icon: "house", isSelected: selection == [.dashboard]) {
                    selection = [.dashboard]
                    onApplyFilters()
                }

                sidebarRow(title: "All Assets", icon: "play.rectangle.on.rectangle", isSelected: selection == [.allAssets], count: unreviewedCount > 0 ? unreviewedCount : nil) {
                    selection = [.allAssets]
                    onApplyFilters()
                }

                sidebarRow(title: "Actors Gallery", icon: "person.2.crop.square.stack", isSelected: selection == [.actorGallery]) {
                    selection = [.actorGallery]
                    onApplyFilters()
                }

                sidebarRow(title: "Tags Gallery", icon: "tag.square.fill", isSelected: selection == [.tagGallery]) {
                    selection = [.tagGallery]
                    onApplyFilters()
                }
            }
            
            if !smartCollections.isEmpty {
                DisclosureGroup(isExpanded: $isSmartCollectionsExpanded) {
                    ForEach(smartCollections) { sc in
                        sidebarRow(title: sc.name, icon: "folder.fill", isSelected: selection == [.smartCollection(sc.id, sc.name)]) {
                            selection = [.smartCollection(sc.id, sc.name)]
                            onApplyFilters()
                        }
                        // Add context menu to delete
                        .contextMenu {
                            Button(role: .destructive) {
                                NotificationCenter.default.post(name: NSNotification.Name("DeleteSmartCollection"), object: sc.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } label: { Text("Smart Collections").font(.headline) }
            }
            
            DisclosureGroup(isExpanded: $isActorsExpanded) {
                AlphaPickerView(filter: $actorAlphaFilter)
                ForEach(filteredItems(allUniqueActors, by: actorAlphaFilter), id: \.self) { actor in
                    sidebarRow(title: actor, icon: "person", isSelected: selection.contains(.actor(actor)), count: actorCounts[actor]) {
                        toggleSelection(item: .actor(actor))
                    }
                }
            } label: { Text("Actors").font(.headline) }
            
            DisclosureGroup(isExpanded: $isTagsExpanded) {
                AlphaPickerView(filter: $tagAlphaFilter)
                ForEach(filteredItems(allUniqueTags, by: tagAlphaFilter), id: \.self) { tag in
                    sidebarRow(title: tag, icon: "tag", isSelected: selection.contains(.tag(tag)), count: tagCounts[tag]) {
                        toggleSelection(item: .tag(tag))
                    }
                }
            } label: { Text("Tags").font(.headline) }
            
            DisclosureGroup(isExpanded: $isStudiosExpanded) {
                AlphaPickerView(filter: $studioAlphaFilter)
                ForEach(filteredItems(allUniqueStudios, by: studioAlphaFilter), id: \.self) { studio in
                    sidebarRow(title: studio, icon: "building.2", isSelected: selection.contains(.studio(studio)), count: studioCounts[studio]) {
                        toggleSelection(item: .studio(studio))
                    }
                }
            } label: { Text("Studios").font(.headline) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                progressFooter
                
                Divider()
                
                Button(action: {
                    // Send notification to open settings.
                    // Instead of callback, we can use NotificationCenter
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                }) {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .buttonStyle(.plain)
            }
            .background(.ultraThinMaterial)
        }
        .navigationTitle("ViLM")
        .onAppear {
            fetchProfiles()
        }
        .onChange(of: libraryURL) { _, _ in
            fetchProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReloadAssets"))) { _ in
            fetchProfiles()
        }
    }
    
    // MARK: - Helpers
    
    private func fetchProfiles() {
        guard let url = libraryURL else { return }
        Task {
            do {
                let store = try LibraryStore(at: url)
                let allProfiles = try store.fetchAllEntityProfiles()
                var newAkaMap: [String: String] = [:]
                for profile in allProfiles {
                    if profile.id.hasPrefix("actor:") {
                        let mainName = String(profile.id.dropFirst(6))
                        for aka in profile.akas {
                            newAkaMap[aka] = mainName
                        }
                    }
                }
                await MainActor.run {
                    self.profiles = allProfiles
                    self.akaMap = newAkaMap
                }
            } catch {
                print("Failed to fetch profiles in sidebar: \(error)")
            }
        }
    }    
    private func filteredItems(_ items: [String], by letter: Character?) -> [String] {
        guard let letter = letter else { return items }
        return items.filter { $0.uppercased().hasPrefix(String(letter)) }
    }
    
    private func toggleSelection(item: SidebarItem) {
        if selection.contains(item) {
            selection.remove(item)
            if selection.isEmpty {
                selection = [.allAssets]
            }
        } else {
            selection.remove(.allAssets)
            selection.insert(item)
        }
    }
    
    private func sidebarRow(title: String, icon: String, isSelected: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let count = count {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                if isSelected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
    
    // MARK: - Progress Footer
    private var progressFooter: some View {
        VStack(spacing: 8) {
#if os(iOS)
            Button(action: onApplyFilters) {
                Text("Apply Filters & View Assets")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
#endif
            
            Divider()
            HStack {
                Text("Review Progress")
                Spacer()
                Text("\(Int(reviewProgress * 100))%")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            ProgressView(value: reviewProgress)
                .tint(reviewProgress == 1.0 ? .green : .blue)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}
