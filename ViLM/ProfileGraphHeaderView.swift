// ProfileGraphHeaderView.swift
// The header shown on an entity's profile page: collapsible related-links
// explorer (studios, co-actors, tags, series), the photo strip and
// full-screen pinch-zoomable photo browser, and the rename/edit/delete menu.

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
    @State private var isExpanded: Bool

    init(filteredAssets: [Asset], sidebarSelection: Binding<Set<SidebarItem>>, currentSelection: SidebarItem, libraryURL: URL?) {
        self.filteredAssets = filteredAssets
        self._sidebarSelection = sidebarSelection
        self.currentSelection = currentSelection
        self.libraryURL = libraryURL
        // A series graph is purely a jumping-off point (no photo/bio), so it
        // defaults closed. Actor/studio profiles carry a photo and bio worth
        // showing, so they default open.
        let isSeries: Bool = { if case .series = currentSelection { return true }; return false }()
        _isExpanded = State(initialValue: !isSeries)
    }
    
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
            HStack(alignment: .top) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Explore Related Links")
                                .font(.headline)
                            Text(exploreSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
                            Label("Edit Profile", systemImage: "person.text.rectangle")
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

            if isExpanded {
            if let profile = entityProfile, !profile.akas.isEmpty {
                Text("AKA: \(profile.akas.joined(separator: ", "))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
                        
                        if let rating = profile.rating, rating > 0 {
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { star in
                                    Image(systemName: star <= rating ? "star.fill" : "star")
                                        .font(.caption)
                                        .foregroundColor(.yellow)
                                }
                            }
                            .accessibilityLabel("Rated \(rating) of 5 stars")
                        }

                        let metadataStrings: [String] = [
                            profile.gender.map { "Gender: \($0)" },
                            profile.hairColor.map { "Hair Color: \($0)" },
                            // resolvedBirthYear rather than birthYear: a record
                            // that carries only a full date still shows a year.
                            profile.resolvedBirthYear.map { "Birth Year: \($0)" },
                            profile.countryOfOrigin.map { "Country: \($0)" }
                        ].compactMap { $0 }

                        if !metadataStrings.isEmpty {
                            Text(metadataStrings.joined(separator: " • "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Career span gets its own line rather than joining the
                        // bulleted list: it is a sentence, not a field, and it
                        // would crowd the line out on a phone.
                        //
                        // Every part of it is computed from stored years, so the
                        // "years active" figure moves on its own each year
                        // instead of going stale.
                        if let career = profile.careerDisplay {
                            Label(career, systemImage: "calendar")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Career: \(career)")
                        }

                    }
                }
            }

            // Links get a full-width section of their own rather than a line in
            // the identity block: a record can carry a dozen of them, and they
            // need room to wrap. The home page joins them instead of keeping a
            // separate "Visit Website" line, so there is one place to look.
            if let profile = entityProfile {
                EntityLinksView(links: displayLinks(for: profile))
            }

            if let profile = entityProfile, !profile.tags.isEmpty {
                tagSection(title: "Profile Tags", items: profile.tags, color: .accentColor) { item in
                    .tag(item)
                }
            }
            
            if let profile = entityProfile, !galleryOnlyTokens(for: profile).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Photo Gallery").font(.subheadline).foregroundColor(.secondary).fontWeight(.medium)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(galleryOnlyTokens(for: profile), id: \.self) { url in
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
                EntityProfileEditorView(libraryURL: libraryURL, entityId: id, profile: ownerRawProfile(for: id), onSave: saveProfile)
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
                let allImageIdentifiers = ["primary"] + galleryOnlyTokens(for: profile)

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

    // Gallery entries that are actually *additional* photos. Tokens equal to
    // the primary URL, and the local://primary placeholder, both resolve to
    // the primary photo file — listing them alongside the header photo (or
    // as extra pages in the full-screen browser) showed the primary twice.
    private func galleryOnlyTokens(for profile: EntityProfile) -> [String] {
        profile.galleryUrls.filter {
            $0 != profile.photoUrl && $0 != ProfileImageNaming.localPrimaryToken
        }
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
            ZoomablePhoto {
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
            // Fresh zoom state per photo — otherwise the pager's fixed three
            // HStack slots would carry over a stale scale as `index` changes
            // which photo occupies a given slot.
            .id(identifier)
        }

        // Resolves the on-disk file for an identifier (no I/O), matching the
        // naming scheme ProfileImageView writes with.
        private func fileURL(for identifier: String) -> URL? {
            guard let libraryURL else { return nil }
            let dir = libraryURL.appendingPathComponent(".catalog/profiles")
            let isGallery = identifier != "primary" && identifier != primaryPhotoUrl
            let fileName = ProfileImageNaming.fileName(for: entityId, token: identifier, isGallery: isGallery)
            return dir.appendingPathComponent(fileName)
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
                // Decode off the main thread, but build the SwiftUI Image on the
                // main actor (its initializer is main-actor isolated).
                let platformImage = await Task.detached { () -> PlatformImage? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return PlatformImage(data: data)
                }.value
                if let platformImage { images[identifier] = Image(platformImage: platformImage) }
            }
        }
    }

    /// Pinch-to-zoom for a single full-screen photo. Deliberately scoped to
    /// zoom-in-place (no panning): the pager's own swipe-to-advance uses a
    /// plain one-finger `DragGesture`, and a competing one-finger pan gesture
    /// here would fight it for recognition. Pinch (two fingers) and
    /// double-tap don't overlap with that at all, so they're safe to attach
    /// with `.simultaneousGesture` without touching the pager's gesture.
    private struct ZoomablePhoto<Content: View>: View {
        @ViewBuilder let content: () -> Content

        @State private var scale: CGFloat = 1
        @State private var lastScale: CGFloat = 1

        private let minScale: CGFloat = 1
        private let maxScale: CGFloat = 5

        var body: some View {
            content()
                .scaleEffect(scale)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value, minScale), maxScale)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = 1
                            lastScale = 1
                        }
                    }
                )
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
                        // No -w here. The HStack is 3w wide and the enclosing
                        // .frame(width: w) CENTRES it, which already places the
                        // middle page -- wrapped(index) -- in the visible
                        // window. Subtracting another w shifted one page
                        // further, so tapping a thumbnail opened the NEXT photo.
                        //
                        // This restores the invariant settle() already documents:
                        // at dragOffset == 0 the visible page is wrapped(index).
                        .offset(x: dragOffset)
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
                // Kindle-style edge taps, in addition to swiping.
                //
                // Each zone is a quarter of the width, which leaves the middle
                // half clear. That gap is deliberate: the photo under this
                // overlay takes a double-tap to reset zoom, and people pinch
                // and double-tap toward the centre. Full-width zones would
                // turn every stray double-tap into two page turns.
                //
                // Reuses settle(), so a tap and a swipe animate identically.
                .overlay {
                    if count > 1 {
                        HStack(spacing: 0) {
                            tapZone(step: -1, width: w, label: "Previous photo")
                            Spacer(minLength: 0)
                            tapZone(step: 1, width: w, label: "Next photo")
                        }
                    }
                }
            }
        }

        private func tapZone(step: Int, width w: CGFloat, label: String) -> some View {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: w * 0.25)
                .onTapGesture {
                    guard !isSettling else { return }
                    settle(step: step, width: w)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(label)
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
    
    // Framed as an invitation to explore, not a set of active filters.
    private var exploreSubtitle: String {
        if let name = currentName, !name.isEmpty {
            return "Actors, studios, and tags connected to \(name)"
        }
        return "Actors, studios, and tags"
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
        guard libraryURL != nil, let id = currentEntityId else { return }
        do {
            // DISPLAY is the merged view across every open library that has
            // this profile (higher precedence wins, lists union) — an actor
            // whose rating lives only in an attachment must still show it.
            var layers: [[String: EntityProfile]] = []
            for libURL in LibrarySession.shared.allURLs {
                if let profile = try LibraryStore(at: libURL).fetchEntityProfile(for: id) {
                    layers.append([id: profile])
                }
            }
            entityProfile = MergeSemantics.mergedProfileView(ordered: layers)[id]
        } catch {
            print("Failed to fetch profile: \(error)")
        }
    }

    /// The OWNING library's raw copy, for the edit sheet. Never hand the
    /// merged view to an editor: saving merged form state wholesale would
    /// copy other libraries' fields into the owner — an accidental merge.
    private func ownerRawProfile(for id: String) -> EntityProfile? {
        (try? LibrarySession.shared.store(forProfile: id).fetchEntityProfile(for: id)) ?? nil
    }

    private func saveProfile(_ profile: EntityProfile) {
        guard libraryURL != nil else { return }
        do {
            // Writes land in the profile's owning library only.
            let store = try LibrarySession.shared.store(forProfile: profile.id)
            try store.saveEntityProfile(profile)
            self.entityProfile = profile
            // "ReloadAssets" is this app's general "library data changed"
            // signal — every view sharing the centralized profile cache
            // listens for it, not just asset lists.
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch {
            print("Failed to save profile: \(error)")
            AppErrorReporter.report("Couldn't save the profile: \(error.localizedDescription)")
        }
    }

    private func deleteProfile() {
        guard libraryURL != nil, let id = currentEntityId else { return }
        do {
            let store = try LibrarySession.shared.store(forProfile: id)
            try store.deleteEntityProfile(for: id)
            self.entityProfile = nil
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)

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
            AppErrorReporter.report("Couldn't delete the profile: \(error.localizedDescription)")
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
            // A global rename applies to EVERY open library: the user sees
            // one tag space, and renaming in only one would leave the union
            // showing old and new names side by side. Each library runs its
            // own hardened files-first rename; nothing crosses libraries.
            _ = url
            for libURL in LibrarySession.shared.allURLs {
                let store = try LibraryStore(at: libURL)
                try store.renameTagGlobally(oldTag: id, newTag: newTag)
            }

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
            AppErrorReporter.report("Couldn't rename across the library: \(error.localizedDescription)")
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
    
    /// The home page ahead of imported links.
    ///
    /// The home page is the one the operator typed, so it leads. It carries an
    /// explicit label because `displayLabel` would otherwise fall back to the
    /// bare host, which reads as an accident next to named links.
    ///
    /// `EntityLinksView` de-duplicates by URL, so a home page that an importer
    /// also supplied appears once, under this label.
    private func displayLinks(for profile: EntityProfile) -> [EntityLink] {
        let trimmed = profile.homePage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return profile.links }
        return [EntityLink(url: trimmed, label: "Home Page")] + profile.links
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
