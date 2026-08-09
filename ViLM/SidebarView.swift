// SidebarView.swift
// The sidebar: fixed sections (Dashboard, All Assets, galleries), saved
// Smart Collections, and quick actor/tag/studio lists derived from the
// library (cached, recomputed on data changes).

import SwiftUI
import UniformTypeIdentifiers
import LibraryCore

/// A studio being renamed. `String` is not `Identifiable`.
private struct RenamingStudio: Identifiable {
    let value: String
    var id: String { value }
}

struct SidebarView: View {
    @State private var renamingStudio: RenamingStudio?
    @Binding var selection: Set<SidebarItem>
    let assets: [Asset]
    let libraryURL: URL?
    // Loaded once at the ContentView level and shared across every screen
    // that needs entity profiles, instead of re-fetching independently here.
    let entityProfiles: EntityProfileIndex
    /// Every profile photo filename across the open libraries.
    ///
    /// ⚠️ Passed in rather than listed here. `ContentView` already unions the
    /// directories on each profile reload; listing them again would put a
    /// filesystem walk on the sidebar's recompute, which runs on every asset
    /// change.
    var profileImageFileNames: Set<String> = []
    let onApplyFilters: () -> Void
    /// Multi-library session: attach a picked library / detach an open one.
    var onAttachLibrary: (URL) -> Void = { _ in }
    var onDetachLibrary: (URL) -> Void = { _ in }
    /// Opens the Sync Actors page (converge actor databases across open libraries).
    var onSyncActors: () -> Void = {}

    @ObservedObject private var session = LibrarySession.shared
    @State private var isShowingAttachPicker = false

    private var profiles: [EntityProfile] { entityProfiles.all }

    @State private var isActorsExpanded = true
    @State private var isTagsExpanded = true
    @State private var isStudiosExpanded = true
    
    @State private var actorAlphaFilter: Character? = nil
    @State private var tagAlphaFilter: Character? = nil
    @State private var studioAlphaFilter: Character? = nil

    @Environment(\.usesStackNavigation) private var usesStackNavigation

    // True when at least one actor/tag/studio/series filter is toggled.
    private var hasActiveEntityFilters: Bool {
        selection.contains { item in
            switch item {
            case .actor, .tag, .studio, .series: return true
            default: return false
            }
        }
    }
    
    // MARK: - Cached Derived Data
    //
    // The sidebar re-renders on every selection toggle. Deriving these by
    // flat-mapping the whole library each render (six passes) does not scale,
    // so they are computed once whenever `assets` or the profiles change.
    @State private var allUniqueActors: [String] = []
    @State private var allUniqueTags: [String] = []
    @State private var allUniqueStudios: [String] = []
    @State private var actorCounts: [String: Int] = [:]
    @State private var tagCounts: [String: Int] = [:]
    @State private var studioCounts: [String: Int] = [:]
    @State private var reviewProgress: Double = 0
    @State private var unreviewedCount: Int = 0
    /// Actors with no photograph anywhere, for the badge beside Actors Gallery.
    ///
    /// ⚠️ COMPUTED, never assumed. A batch enrichment run filled 137 photo
    /// URLs, so any figure written down goes stale the moment one is added.
    ///
    /// ⚠️ Federation-aware by construction: `entityProfiles` is the merged view
    /// across every open library and `profileImageFileNames` is their union, so
    /// an actor whose only photo lives in an attachment does not read as
    /// photo-less.
    @State private var missingPhotoCount: Int = 0

    private func recomputeDerivedData() {
        var actorSet = Set<String>()
        var tagSet = Set<String>()
        var studioSet = Set<String>()
        var newActorCounts = [String: Int]()
        var newTagCounts = [String: Int]()
        var newStudioCounts = [String: Int]()
        var reviewedCount = 0
        var unreviewed = 0

        // Computed once here rather than as a property, so the per-tag
        // lookups below stay O(1) instead of rebuilding the whole map on
        // every access.
        var akaMap: [String: String] = [:]
        for profile in profiles where profile.type == "actor" {
            for aka in profile.akas { akaMap[aka] = profile.name }
        }

        for asset in assets {
            if asset.status == .reviewed { reviewedCount += 1 }
            if asset.status == .unreviewed { unreviewed += 1 }

            var actorsInAsset = Set<String>()
            for tag in asset.tags {
                if tag.hasPrefix("actor:") {
                    let mapped = akaMap[String(tag.dropFirst(6))] ?? String(tag.dropFirst(6))
                    actorSet.insert(mapped)
                    actorsInAsset.insert(mapped)
                } else if tag.hasPrefix("tag:") {
                    let name = String(tag.dropFirst(4))
                    tagSet.insert(name)
                    newTagCounts[name, default: 0] += 1
                } else if tag.hasPrefix("studio:") {
                    let name = String(tag.dropFirst(7))
                    studioSet.insert(name)
                    newStudioCounts[name, default: 0] += 1
                }
            }
            // Count each actor once per asset (handles duplicate AKA mappings).
            for actor in actorsInAsset {
                newActorCounts[actor, default: 0] += 1
            }
        }

        // Profiles may exist without any assets referencing them yet.
        for profile in profiles {
            // ⭐ Split by the type column and named by the name column —
            // neither survives being derived from a uid.
            switch profile.type {
            case "actor":  actorSet.insert(profile.name)
            case "tag":    tagSet.insert(profile.name)
            case "studio": studioSet.insert(profile.name)
            default:       break
            }
        }

        allUniqueActors = actorSet.sorted()
        allUniqueTags = tagSet.sorted()
        allUniqueStudios = studioSet.sorted()
        actorCounts = newActorCounts
        tagCounts = newTagCounts
        studioCounts = newStudioCounts
        unreviewedCount = unreviewed
        // 🚨 The filename comes from the profile's OWN id — photo files are
        // named after it, so deriving one from the name finds nothing once ids
        // are uids and every actor would read as photo-less.
        missingPhotoCount = entityProfiles.actors.reduce(into: 0) { count, profile in
            if profile.photoUrl != nil { return }
            let safeId = ProfileImageNaming.safeId(for: profile.id)
            let hasLocal = profileImageFileNames.contains("\(safeId).jpg")
                || profileImageFileNames.contains { $0.hasPrefix("\(safeId)_") }
            if !hasLocal { count += 1 }
        }
        reviewProgress = assets.isEmpty ? 0 : Double(reviewedCount) / Double(assets.count)
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

                // ⭐ Mirrors the unreviewed-videos badge exactly — same row
                // helper, same placement, same styling. A consistency fix, not
                // a new pattern.
                sidebarRow(title: "Actors Gallery", icon: "person.2.crop.square.stack",
                           isSelected: selection == [.actorGallery],
                           count: missingPhotoCount > 0 ? missingPhotoCount : nil) {
                    selection = [.actorGallery]
                    onApplyFilters()
                }

                sidebarRow(title: "Tags Gallery", icon: "tag.square.fill", isSelected: selection == [.tagGallery]) {
                    selection = [.tagGallery]
                    onApplyFilters()
                }

                sidebarRow(title: "Series Gallery", icon: "rectangle.stack.fill", isSelected: selection == [.seriesGallery]) {
                    selection = [.seriesGallery]
                    onApplyFilters()
                }

                sidebarRow(title: "Studios Gallery", icon: "building.2.fill", isSelected: selection == [.studioGallery]) {
                    selection = [.studioGallery]
                    onApplyFilters()
                }
            }

            // The federated session: primary + attachments in precedence
            // order (attach order — which is also who wins merged-view
            // conflicts). Paths, not folder names: two libraries can both be
            // called "Videos"; the volume/route is what tells them apart.
            if libraryURL != nil {
                Section("Open Libraries") {
                    if let primary = session.primaryURL {
                        openLibraryRow(path: displayPath(primary), caption: "Main")
                    }
                    ForEach(session.attachedURLs, id: \.self) { url in
                        openLibraryRow(path: displayPath(url), caption: "Attached — closes with the app") {
                            onDetachLibrary(url)
                        }
                    }
                    Button {
                        isShowingAttachPicker = true
                    } label: {
                        Label("Attach Library…", systemImage: "plus.rectangle.on.folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)

                    if session.isFederated {
                        Button {
                            onSyncActors()
                        } label: {
                            Label("Sync Actors…", systemImage: "person.2.badge.gearshape")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
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
                    .contextMenu {
                        Button {
                            renamingStudio = RenamingStudio(value: studio)
                        } label: {
                            Label("Rename Studio…", systemImage: "pencil")
                        }
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
        .sheet(item: $renamingStudio) { studio in
            EntityRenameSheet(category: "studio", currentName: studio.value,
                              existingNames: Array(studioCounts.keys)) { _ in
                selection.remove(.studio(studio.value))
                recomputeDerivedData()
            }
        }
        .fileImporter(isPresented: $isShowingAttachPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { onAttachLibrary(url) }
        }
        .onAppear {
            recomputeDerivedData()
        }
        .onChange(of: assets) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: entityProfiles) { _, _ in
            recomputeDerivedData()
        }
    }

    // MARK: - Helpers

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
    
    /// An "Open Libraries" row: the library's PATH (never just its folder
    /// name — two libraries can share one), a role caption, and for
    /// attachments an eject button.
    private func openLibraryRow(path: String, caption: String, onDetach: (() -> Void)? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(path)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.head)
                Text(caption)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let onDetach {
                Button(action: onDetach) {
                    Image(systemName: "eject.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Detach library")
            }
        }
    }

    /// Prettified full path (~ for home, volume name for external drives) —
    /// libraries are identified by PATH, never just folder name.
    private func displayPath(_ url: URL) -> String {
        session.fullLabel(for: url)
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
            // Only needed in the compact stack layout, and only once filters
            // are toggled: in the split layout the content pane updates live,
            // and top-level sections already navigate on tap.
            if usesStackNavigation && hasActiveEntityFilters {
                Button(action: {
                    // Filters apply on the assets grid; drop any section
                    // selection so this always lands on the filtered grid.
                    selection.subtract([.dashboard, .actorGallery, .tagGallery, .seriesGallery, .studioGallery])
                    onApplyFilters()
                }) {
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
            }

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
