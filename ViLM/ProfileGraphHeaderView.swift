import SwiftUI
import LibraryCore

struct ProfileGraphHeaderView: View {
    let filteredAssets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let currentSelection: SidebarItem
    let libraryURL: URL?
    
    @State private var entityProfile: EntityProfile?
    @State private var isShowingEditor = false
    @State private var isShowingRenameDialog = false
    @State private var selectedFullImageIdentifier: String? = nil
    @State private var newGlobalName = ""
    
    private var relatedStudios: [String] {
        let studios = filteredAssets.flatMap { $0.studios }
        return uniqueEntities(from: studios, excluding: currentSelectionName(for: "studio"))
    }
    
    private var relatedActors: [String] {
        let actors = filteredAssets.flatMap { $0.actors }
        return uniqueEntities(from: actors, excluding: currentSelectionName(for: "actor"))
    }
    
    private var relatedTags: [String] {
        let tags = filteredAssets.flatMap { $0.actions }
        return uniqueEntities(from: tags, excluding: currentSelectionName(for: "tag"))
    }
    
    private var relatedSeries: [String] {
        let series = filteredAssets.compactMap { $0.videoName }.filter { !$0.isEmpty }
        return uniqueEntities(from: series, excluding: currentSelectionName(for: "series"))
    }
    
    private func currentSelectionName(for type: String) -> String? {
        switch currentSelection {
        case .studio(let name) where type == "studio": return name
        case .actor(let name) where type == "actor": return name
        case .tag(let name) where type == "tag": return name
        case .series(let name) where type == "series": return name
        default: return nil
        }
    }
    
    private var currentName: String? {
        switch currentSelection {
        case .actor(let name): return name
        case .studio(let name): return name
        case .tag(let name): return name
        case .series(let name): return name
        default: return nil
        }
    }
    
    private func uniqueEntities(from list: [String], excluding: String?) -> [String] {
        var set = Set(list)
        if let excluding = excluding {
            set.remove(excluding)
        }
        return Array(set).sorted()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(titleText)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                
                if let name = currentName {
                    Button("Rename Globally") {
                        newGlobalName = name
                        isShowingRenameDialog = true
                    }
                    .buttonStyle(.bordered)
                }
                
                if isEditableEntity {
                    Button("Edit Bio") {
                        isShowingEditor = true
                    }
                    .buttonStyle(.bordered)
                    if filteredAssets.count == 0 && entityProfile != nil {
                        Button("Delete Profile", role: .destructive) {
                            deleteProfile()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            }
            
            if let profile = entityProfile {
                HStack(alignment: .top, spacing: 16) {
                    Button(action: {
                        selectedFullImageIdentifier = "primary"
                    }) {
                        ProfileImageView(libraryURL: libraryURL, entityId: currentEntityId ?? "unknown", photoUrl: profile.photoUrl, isGallery: false) { image in
                            Color.clear
                                .overlay(
                                    image
                                        .resizable()
                                        .scaledToFill(),
                                    alignment: .top
                                )
                        } placeholder: {
                            ZStack {
                                Circle().fill(Color.secondary.opacity(0.2))
                                Image(systemName: "person.fill").font(.system(size: 40)).foregroundColor(.secondary)
                                if profile.photoUrl != nil {
                                    ProgressView()
                                }
                            }
                        }
                        .frame(width: 80, height: 80)
                        .contentShape(Circle())
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        if let bio = profile.bio {
                            Text(bio).font(.body)
                        }
                        
                        let metadataStrings: [String] = [
                            profile.gender.map { "Gender: \($0)" },
                            profile.hairColor.map { "Hair Color: \($0)" },
                            profile.birthYear.map { "Birth Year: \($0)" },
                            profile.countryOfOrigin.map { "Country: \($0)" }
                        ].compactMap { $0 }
                        
                        if !metadataStrings.isEmpty {
                            Text(metadataStrings.joined(separator: " • "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let homePage = profile.homePage, let url = URL(string: homePage) {
                            Link("Visit Website", destination: url)
                                .font(.callout)
                        }
                    }
                }
            }
            
            if let profile = entityProfile, !profile.tags.isEmpty {
                tagSection(title: "Profile Tags", items: profile.tags, color: .accentColor) { item in
                    .tag(item)
                }
            }
            
            if let profile = entityProfile, !profile.galleryUrls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Photo Gallery").font(.subheadline).foregroundColor(.secondary).fontWeight(.medium)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(profile.galleryUrls, id: \.self) { url in
                                Button(action: {
                                    selectedFullImageIdentifier = url
                                }) {
                                    ProfileImageView(libraryURL: libraryURL, entityId: currentEntityId ?? "unknown", photoUrl: url, isGallery: url != profile.photoUrl) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        ZStack {
                                            Rectangle().fill(Color.secondary.opacity(0.2))
                                            ProgressView()
                                        }
                                    }
                                    .frame(width: 80, height: 80)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            
            if !relatedStudios.isEmpty {
                tagSection(title: "Studios", items: relatedStudios, color: .purple) { item in
                    .studio(item)
                }
            }
            if !relatedActors.isEmpty {
                tagSection(title: "Co-Actors", items: relatedActors, color: .blue) { item in
                    .actor(item)
                }
            }
            if !relatedTags.isEmpty {
                tagSection(title: "Tags", items: relatedTags, color: .green) { item in
                    .tag(item)
                }
            }
            if !relatedSeries.isEmpty {
                tagSection(title: "Video Series", items: relatedSeries, color: .orange, isAdditive: true) { item in
                    .series(item)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
        .onAppear { fetchProfile() }
        .onChange(of: currentSelection) { old, new in fetchProfile() }
        .sheet(isPresented: $isShowingEditor) {
            if let id = currentEntityId {
                EntityProfileEditorView(libraryURL: libraryURL, entityId: id, profile: entityProfile, onSave: saveProfile)
            }
        }
        .alert("Rename Globally", isPresented: $isShowingRenameDialog) {
            TextField("New Name", text: $newGlobalName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { performGlobalRename() }
        } message: {
            Text("This will rename the entity across all videos in your library.")
        }
        .sheet(isPresented: Binding(
            get: { selectedFullImageIdentifier != nil },
            set: { if !$0 { selectedFullImageIdentifier = nil } }
        )) {
            if let profile = entityProfile {
                let allImageIdentifiers: [String] = {
                    var list = ["primary"]
                    for url in profile.galleryUrls where url != profile.photoUrl {
                        list.append(url)
                    }
                    return list
                }()
                
                NavigationStack {
                    TabView(selection: $selectedFullImageIdentifier) {
                        ForEach(allImageIdentifiers, id: \.self) { item in
                            let isGallery = item != "primary" && item != profile.photoUrl
                            let photoUrl = item == "primary" ? profile.photoUrl : item
                            
                            ProfileImageView(libraryURL: libraryURL, entityId: currentEntityId ?? "unknown", photoUrl: photoUrl, isGallery: isGallery) { image in
                                image
                                    .resizable()
                                    .scaledToFit()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .tag(item as String?)
                        }
                    }
                    #if os(iOS)
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    #endif
                    .background(Color.black)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                selectedFullImageIdentifier = nil
                            }
                        }
                    }
                }
                .presentationDetents([.large])
            }
        }
    }
    
    struct IdentifiableString: Identifiable {
        let id: String
    }
    
    private var titleText: String {
        switch currentSelection {
        case .actor(let name): return "\(name)'s Profile Graph"
        case .studio(let name): return "\(name) Studio Graph"
        case .tag(let name): return "Tag Graph: \(name)"
        case .series(let name): return "Series Graph: \(name)"
        case .dashboard, .allAssets, .actorGallery, .tagGallery: return ""
        }
    }
    
    private var currentEntityId: String? {
        switch currentSelection {
        case .actor(let name): return "actor:\(name)"
        case .studio(let name): return "studio:\(name)"
        case .tag(let name): return "tag:\(name)"
        case .series(let name): return "series:\(name)"
        default: return nil
        }
    }
    
    private var isEditableEntity: Bool {
        switch currentSelection {
        case .actor, .studio: return true
        default: return false
        }
    }
    
    private func fetchProfile() {
        guard let url = libraryURL, let id = currentEntityId else { return }
        do {
            let store = try LibraryStore(at: url)
            entityProfile = try store.fetchEntityProfile(for: id)
        } catch {
            print("Failed to fetch profile: \(error)")
        }
    }

    private func saveProfile(_ profile: EntityProfile) {
        guard let url = libraryURL else { return }
        do {
            let store = try LibraryStore(at: url)
            try store.saveEntityProfile(profile)
            self.entityProfile = profile
        } catch {
            print("Failed to save profile: \(error)")
        }
    }
    
    private func deleteProfile() {
        guard let url = libraryURL, let id = currentEntityId else { return }
        do {
            let store = try LibraryStore(at: url)
            try store.deleteEntityProfile(for: id)
            self.entityProfile = nil
            
            // Navigate back to the appropriate gallery
            let parts = id.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return }
            let category = String(parts[0])
            if category == "actor" {
                sidebarSelection = [.actorGallery]
            } else if category == "tag" {
                sidebarSelection = [.tagGallery]
            } else {
                sidebarSelection = [.allAssets]
            }
        } catch {
            print("Failed to delete profile: \(error)")
        }
    }
    
    private func performGlobalRename() {
        guard let url = libraryURL, let id = currentEntityId, !newGlobalName.isEmpty else { return }
        
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let category = String(parts[0])
        let newTag = "\(category):\(newGlobalName)"
        
        do {
            let store = try LibraryStore(at: url)
            try store.renameTagGlobally(oldTag: id, newTag: newTag)
            
            var pivotItem: SidebarItem
            switch category {
            case "actor": pivotItem = .actor(newGlobalName)
            case "studio": pivotItem = .studio(newGlobalName)
            default: pivotItem = .tag(newGlobalName)
            }
            sidebarSelection = [pivotItem]
            
            fetchProfile()
        } catch {
            print("Failed to rename globally: \(error)")
        }
    }
    
    private func route(for item: SidebarItem, fallbackName: String) -> AppRoute {
        switch item {
        case .actor(let name): return .entityProfile(category: "actor", name: name)
        case .studio(let name): return .entityProfile(category: "studio", name: name)
        case .tag(let name): return .entityProfile(category: "tag", name: name)
        case .series(let name): return .entityProfile(category: "series", name: name)
        default: return .entityProfile(category: "unknown", name: fallbackName)
        }
    }
    
    private func tagSection(title: String, items: [String], color: Color, isAdditive: Bool = false, itemType: @escaping (String) -> SidebarItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundColor(.secondary).fontWeight(.medium)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    let sidebarItem = itemType(item)
                    
                    #if os(iOS)
                    TagBubble(label: item, color: color, navRoute: route(for: sidebarItem, fallbackName: item))
                    #else
                    TagBubble(label: item, color: color, onPivot: {
                        if isAdditive {
                            sidebarSelection.insert(sidebarItem)
                        } else {
                            sidebarSelection = [sidebarItem]
                        }
                    })
                    #endif
                }
            }
        }
    }
}
