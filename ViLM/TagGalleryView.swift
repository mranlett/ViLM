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
    /// The operator's chosen spelling for each tag, when one has been recorded.
    /// Empty is fine — canonical spellings then fall back to the most-used one.
    @State private var tagVocabulary: [TagRecord] = []
    @State private var allUniqueTags: [String] = []
    @State private var tagCounts: [String: Int] = [:]
    @State private var tagScopes: [String: TagScope] = [:]

    /// Best-effort: the gallery still folds spellings without a vocabulary, it
    /// just falls back to the most-used one rather than the operator's choice.
    /// A federated view has no single library to read, which is also fine.
    private func loadTagVocabulary() {
        guard let libraryURL else { return }
        tagVocabulary = (try? LibraryStore(at: libraryURL).fetchTagVocabulary()) ?? []
    }

    private func recomputeTags() {
        let tagProfiles = entityProfiles.filter { $0.key.hasPrefix("tag:") }
        let actorProfiles = entityProfiles.filter { $0.key.hasPrefix("actor:") }

        // Two spellings of one tag are one tag. Without this the gallery
        // renders them as separate cards with separate counts, which is what
        // the operator sees even after the vocabulary has folded them —
        // identity is folded in one place and display was not.
        //
        // Every raw occurrence is collected, repeats included: repetition is
        // what decides which spelling is the common one.
        var occurrences: [String] = []
        for asset in assets {
            for tag in asset.tags where tag.hasPrefix("tag:") {
                occurrences.append(String(tag.dropFirst(4)))
            }
        }
        for profile in actorProfiles.values { occurrences.append(contentsOf: profile.tags) }
        for key in tagProfiles.keys { occurrences.append(String(key.dropFirst(4))) }

        let canonical = TagVocabulary.canonicalSpellings(occurrences, preferring: tagVocabulary)
        func display(_ name: String) -> String { canonical[name] ?? name }

        var filmTagSet = Set<String>()
        for asset in assets {
            for tag in asset.tags where tag.hasPrefix("tag:") {
                filmTagSet.insert(display(String(tag.dropFirst(4))))
            }
        }
        for key in tagProfiles.keys {
            filmTagSet.insert(display(String(key.dropFirst(4))))
        }

        var actorTagSet = Set<String>()
        for profile in actorProfiles.values {
            actorTagSet.formUnion(profile.tags.map(display))
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
                matchedNames.insert(display(String(tag.dropFirst(4))))
            }
            for actor in asset.actors {
                if let profile = actorProfiles["actor:\(actor)"] {
                    matchedNames.formUnion(profile.tags.map(display))
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
                    // Adaptive rather than two fixed columns: at two columns a
                    // phone cell is ~170pt, which is what squeezed the tag name
                    // to about seven characters. Adaptive gives each cell a
                    // real minimum width and lets the column count follow the
                    // window — one or two on a phone, more on a Mac.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
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
            loadTagVocabulary()
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

    private var scopeLabel: String {
        switch scope {
        case .filmOnly: return "Film"
        case .actorOnly: return "Actor"
        case .shared: return "Shared"
        }
    }

    // Text-first. The name is the content; everything else is metadata about
    // it, so the name gets the full width of the cell and nothing competes
    // with it horizontally.
    //
    // Measured against the real vocabulary: 13 of 30 tags exceed 7 characters
    // and the longest is 18, so the previous layout truncated 43% of them. The
    // recorded decision is to be ready for a provider vocabulary "ten thousand
    // long", which rules out tuning for today's shortest names.
    //
    // Three things were removed rather than shrunk:
    //   • the leading icon — it duplicated the scope the label already states
    //   • the scope WORD beside the count — same duplication, second copy
    //   • the chevron — the whole cell is the tap target in a grid
    // Each cost horizontal space the name needed and told the reader nothing
    // the card did not already say.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tag)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                // Shrinks before it truncates: a long tag rendered small is
                // still readable, a truncated one is a different tag.
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text("\(assetsCount) video\(assetsCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // The scope, stated ONCE, as a word. A colour alone is not
                // readable for everyone and an icon needs a legend.
                Text(scopeLabel)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(scopeColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(scopeColor)
            }
        }
        .padding(10)
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
