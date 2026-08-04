// TagGalleryView.swift
// The Tag Gallery: every tag in the library (film tags, actor-profile tags,
// or both) as scope-color-coded cards with match counts; selecting tags
// filters the asset grid.

import SwiftUI
import LibraryCore

enum TagScope {
    /// Applied directly to videos only (`asset.tags` with a "tag:" prefix).
    case filmOnly
    /// Only present in an actor's own profile tags (e.g. "Blonde"), never
    /// applied directly to a video.
    case actorOnly
    /// Used both ways.
    case shared
}

/// A tag being renamed. `String` is not `Identifiable`, and keying the sheet on
/// the value is what makes it re-present correctly for a different tag.
private struct RenamingTag: Identifiable {
    let value: String
    var id: String { value }
}

struct TagGalleryView: View {

    @State private var renamingTag: RenamingTag?
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let libraryURL: URL?
    // Loaded once at the ContentView level and shared across every screen
    // that needs entity profiles, instead of re-fetching independently here.
    let entityProfiles: [String: EntityProfile]
    var onPullToRefresh: () async -> Void = {}

    @State private var alphaFilter: Character? = nil
    @State private var isShowingHelp = false

    // Cached once per assets/profiles change instead of re-derived (and
    // re-counted per tag) on every render.
    @State private var allUniqueTags: [String] = []
    @State private var tagCounts: [String: Int] = [:]
    @State private var tagScopes: [String: TagScope] = [:]

    private func recomputeTags() {
        let tagProfiles = entityProfiles.filter { $0.key.hasPrefix("tag:") }
        let actorProfiles = entityProfiles.filter { $0.key.hasPrefix("actor:") }

        var filmTagSet = Set<String>()
        for asset in assets {
            for tag in asset.tags where tag.hasPrefix("tag:") {
                filmTagSet.insert(String(tag.dropFirst(4)))
            }
        }
        for key in tagProfiles.keys {
            filmTagSet.insert(String(key.dropFirst(4)))
        }

        var actorTagSet = Set<String>()
        for profile in actorProfiles.values {
            actorTagSet.formUnion(profile.tags)
        }

        let allNames = filmTagSet.union(actorTagSet)
        var scopes = [String: TagScope]()
        for name in allNames {
            let isFilm = filmTagSet.contains(name)
            let isActor = actorTagSet.contains(name)
            scopes[name] = (isFilm && isActor) ? .shared : (isActor ? .actorOnly : .filmOnly)
        }

        // Single pass over assets — for each one, gather every tag name it
        // matches (its own film tags, plus any of its actors' tags) and
        // increment once per match. O(assets) instead of the O(tags × assets)
        // this used to cost by re-scanning every asset per tag.
        var counts = [String: Int]()
        for asset in assets {
            var matchedNames = Set<String>()
            for tag in asset.tags where tag.hasPrefix("tag:") {
                matchedNames.insert(String(tag.dropFirst(4)))
            }
            for actor in asset.actors {
                if let profile = actorProfiles["actor:\(actor)"] {
                    matchedNames.formUnion(profile.tags)
                }
            }
            for name in matchedNames {
                counts[name, default: 0] += 1
            }
        }

        allUniqueTags = allNames.sorted()
        tagCounts = counts
        tagScopes = scopes
    }

    var filteredTags: [String] {
        guard let letter = alphaFilter else { return allUniqueTags }
        return allUniqueTags.filter { $0.uppercased().hasPrefix(String(letter)) }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AlphaPickerView(filter: $alphaFilter)
                    .padding(.horizontal)
                    .padding(.bottom)
                
                if filteredTags.isEmpty {
                    if allUniqueTags.isEmpty {
                        ContentUnavailableView(
                            "No Tags Yet",
                            systemImage: "tag",
                            description: Text("Tags added to videos or actor profiles will appear here.")
                        )
                        .padding(.top, 80)
                    } else {
                        ContentUnavailableView(
                            "No Matching Tags",
                            systemImage: "tag",
                            description: Text("No tags start with the selected letter.")
                        )
                        .padding(.top, 80)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(filteredTags, id: \.self) { tag in
                            let isSelected = sidebarSelection.contains(.tag(tag))
                            Button(action: {
                                toggleSelection(item: .tag(tag))
                            }) {
                                TagGalleryItemView(
                                    tag: tag,
                                    assetsCount: tagCounts[tag] ?? 0,
                                    isSelected: isSelected,
                                    scope: tagScopes[tag] ?? .filmOnly
                                )
                            }
                            .buttonStyle(.plain)
                            // Right-click on macOS, long-press on iOS — the
                            // gesture the video grid already uses for per-item
                            // actions.
                            .contextMenu {
                                Button {
                                    renamingTag = RenamingTag(value: tag)
                                } label: {
                                    Label("Rename Tag…", systemImage: "pencil")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .refreshable { await onPullToRefresh() }
        #endif
        .navigationTitle("Tags Gallery")
        .toolbar {
            let selectedTagsCount = sidebarSelection.filter { item in
                if case .tag = item { return true }
                return false
            }.count

            if selectedTagsCount > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        // Leaving the gallery switches the content view to the
                        // asset grid filtered by the selected tags.
                        sidebarSelection.remove(.tagGallery)
                    }) {
                        Text("View Matches")
                            .bold()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { isShowingHelp = true }) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help")
                .accessibilityLabel("Help")
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: HelpContent.tagGallery.id)
        }
        .sheet(item: $renamingTag) { tag in
            EntityRenameSheet(category: "tag", currentName: tag.value,
                              existingNames: Array(tagCounts.keys)) { _ in
                sidebarSelection.remove(.tag(tag.value))
            }
        }
        .onAppear {
            recomputeTags()
        }
        .onChange(of: assets) { _, _ in
            recomputeTags()
        }
        .onChange(of: entityProfiles) { _, _ in
            recomputeTags()
        }
    }

    private func toggleSelection(item: SidebarItem) {
        if sidebarSelection.contains(item) {
            sidebarSelection.remove(item)
        } else {
            sidebarSelection.remove(.allAssets)
            sidebarSelection.insert(item)
        }
    }
}

struct TagGalleryItemView: View {
    let tag: String
    let assetsCount: Int
    let isSelected: Bool
    let scope: TagScope

    private var scopeColor: Color {
        switch scope {
        case .filmOnly: return .green
        case .actorOnly: return .blue
        case .shared: return .orange
        }
    }

    private var scopeIcon: String {
        switch scope {
        case .filmOnly: return "tag.fill"
        case .actorOnly: return "person.fill"
        case .shared: return "link"
        }
    }

    private var scopeLabel: String {
        switch scope {
        case .filmOnly: return "Film"
        case .actorOnly: return "Actor"
        case .shared: return "Shared"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: scopeIcon)
                .foregroundColor(scopeColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(tag)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("\(assetsCount) Video\(assetsCount == 1 ? "" : "s")")
                    Text("·")
                    Text(scopeLabel)
                        .foregroundColor(scopeColor)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .imageScale(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tag), \(scopeLabel) tag, \(assetsCount) video\(assetsCount == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        #if os(macOS)
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }
}
