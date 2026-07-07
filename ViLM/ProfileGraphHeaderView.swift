import SwiftUI
import LibraryCore
import CryptoKit

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
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    if let profile = entityProfile, !profile.akas.isEmpty {
                        Text("AKA: \(profile.akas.joined(separator: ", "))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                
                Menu {
                    if let name = currentName {
                        Button {
                            newGlobalName = name
                            isShowingRenameDialog = true
                        } label: {
                            Label("Rename Globally", systemImage: "pencil")
                        }
                    }
                    
                    if isEditableEntity {
                        Button {
                            isShowingEditor = true
                        } label: {
                            Label("Edit Bio", systemImage: "person.text.rectangle")
                        }
                        
                        if filteredAssets.count == 0 && entityProfile != nil {
                            Divider()
                            Button(role: .destructive) {
                                deleteProfile()
                            } label: {
                                Label("Delete Profile", systemImage: "trash")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
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

                FullScreenPhotoBrowser(
                    libraryURL: libraryURL,
                    entityId: currentEntityId ?? "unknown",
                    primaryPhotoUrl: profile.photoUrl,
                    identifiers: allImageIdentifiers,
                    initialIdentifier: selectedFullImageIdentifier ?? "primary",
                    onClose: { selectedFullImageIdentifier = nil }
                )
                .presentationDetents([.large])
            }
        }
    }
    
    struct IdentifiableString: Identifiable {
        let id: String
    }

    // MARK: - Full Screen Photo Browser

    /// Full-screen photo viewer with endless wrap-around swiping.
    private struct FullScreenPhotoBrowser: View {
        let libraryURL: URL?
        let entityId: String
        let primaryPhotoUrl: String?
        let identifiers: [String]      // "primary" + gallery URLs
        let initialIdentifier: String
        let onClose: () -> Void

        @State private var index: Int = 0
        // Full-size images preloaded up front and keyed by identifier, so the
        // pager's neighbouring pages render their photo as they slide in
        // instead of showing the black background until they become active.
        @State private var images: [String: Image] = [:]

        var body: some View {
            NavigationStack {
                WrappingPhotoPager(count: identifiers.count, index: $index) { i in
                    photoPage(for: identifiers[i])
                }
                .background(Color.black)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(identifiers.count > 1 ? "\(index + 1) of \(identifiers.count)" : "")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onClose() }
                    }
                }
                .onAppear {
                    index = identifiers.firstIndex(of: initialIdentifier) ?? 0
                }
                .task { await preloadImages() }
            }
        }

        @ViewBuilder
        private func photoPage(for identifier: String) -> some View {
            if let image = images[identifier] {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Fallback for anything not yet on disk (e.g. a gallery URL not
                // downloaded yet); ProfileImageView will fetch it.
                let isGallery = identifier != "primary" && identifier != primaryPhotoUrl
                let photoUrl = identifier == "primary" ? primaryPhotoUrl : identifier
                ProfileImageView(libraryURL: libraryURL, entityId: entityId, photoUrl: photoUrl, isGallery: isGallery) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        // Resolves the on-disk file for an identifier (no I/O), matching the
        // naming scheme ProfileImageView writes with.
        private func fileURL(for identifier: String) -> URL? {
            guard let libraryURL else { return nil }
            let safeId = entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
            let dir = libraryURL.appendingPathComponent(".catalog/profiles")
            let isGallery = identifier != "primary" && identifier != primaryPhotoUrl
            if isGallery, identifier != "local://primary" {
                let hash = SHA256.hash(data: Data(identifier.utf8)).compactMap { String(format: "%02x", $0) }.joined()
                return dir.appendingPathComponent("\(safeId)_\(hash).jpg")
            }
            return dir.appendingPathComponent("\(safeId).jpg")
        }

        private func preloadImages() async {
            // Load the initially-shown photo first so it appears fastest, then
            // the rest so neighbours are ready before the first swipe.
            let start = identifiers.firstIndex(of: initialIdentifier) ?? 0
            let ordered = (0..<identifiers.count).map { identifiers[(start + $0) % identifiers.count] }
            for identifier in ordered {
                if images[identifier] != nil { continue }
                guard let url = fileURL(for: identifier),
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                let image = await Task.detached { () -> Image? in
                    guard let data = try? Data(contentsOf: url),
                          let platformImage = PlatformImage(data: data) else { return nil }
                    return Image(platformImage: platformImage)
                }.value
                if let image { images[identifier] = image }
            }
        }
    }

    /// A three-page carousel that wraps endlessly with genuinely seamless
    /// transitions.
    ///
    /// Rather than fighting `TabView`'s page style (which animates the large
    /// index jump when snapping past a sentinel), this renders exactly three
    /// pages — previous, current, next — and drives a manual drag offset.
    /// After a swipe animates the neighbour to center, `index` is updated and
    /// the offset reset in the animation's completion handler. Because the
    /// newly-centered page shows the identical photo at the identical screen
    /// position, the recenter is invisible.
    private struct WrappingPhotoPager<Content: View>: View {
        let count: Int
        @Binding var index: Int
        @ViewBuilder let content: (Int) -> Content

        @State private var dragOffset: CGFloat = 0
        @State private var isSettling = false

        var body: some View {
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                Group {
                    if count <= 1 {
                        content(wrapped(index))
                            .frame(width: w, height: geo.size.height)
                    } else {
                        HStack(spacing: 0) {
                            content(wrapped(index - 1)).frame(width: w, height: geo.size.height)
                            content(wrapped(index)).frame(width: w, height: geo.size.height)
                            content(wrapped(index + 1)).frame(width: w, height: geo.size.height)
                        }
                        .offset(x: -w + dragOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard !isSettling else { return }
                                    dragOffset = value.translation.width
                                }
                                .onEnded { value in
                                    guard !isSettling else { return }
                                    let threshold = w * 0.25
                                    if value.translation.width <= -threshold {
                                        settle(step: 1, width: w)
                                    } else if value.translation.width >= threshold {
                                        settle(step: -1, width: w)
                                    } else {
                                        withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                                    }
                                }
                        )
                    }
                }
                .frame(width: w, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
            }
        }

        private func wrapped(_ i: Int) -> Int {
            guard count > 0 else { return 0 }
            return ((i % count) + count) % count
        }

        private func settle(step: Int, width w: CGFloat) {
            isSettling = true
            withAnimation(.easeOut(duration: 0.25)) {
                // step +1 slides content left to reveal the next page; -1 right.
                dragOffset = -CGFloat(step) * w
            } completion: {
                // Recenter onto the now-visible page with no animation. Same
                // pixels at the same position, so nothing appears to move.
                index = wrapped(index + step)
                dragOffset = 0
                isSettling = false
            }
        }
    }
    
    private var titleText: String {
        switch currentSelection {
        case .actor(let name): return "\(name)'s Profile Graph"
        case .studio(let name): return "\(name) Studio Graph"
        case .tag(let name): return "Tag Graph: \(name)"
        case .series(let name): return "Series Graph: \(name)"
        case .dashboard, .allAssets, .actorGallery, .tagGallery, .seriesGallery, .smartCollection: return ""
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
        let normalizedNewName = TagNormalizer.normalize(tagValue: newGlobalName)
        
        do {
            let store = try LibraryStore(at: url)
            try store.renameTagGlobally(oldTag: id, newTag: newTag)
            
            var pivotItem: SidebarItem
            switch category {
            case "actor": pivotItem = .actor(normalizedNewName)
            case "studio": pivotItem = .studio(normalizedNewName)
            default: pivotItem = .tag(normalizedNewName)
            }
            sidebarSelection = [pivotItem]
            
            fetchProfile()
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
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
