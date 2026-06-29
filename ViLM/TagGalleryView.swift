import SwiftUI
import LibraryCore

struct TagGalleryView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let libraryURL: URL?
    
    @State private var tagProfiles: [String: EntityProfile] = [:]
    
    @State private var alphaFilter: Character? = nil
    
    var allUniqueTags: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actionTags = allTags.filter { $0.hasPrefix("tag:") }.map { String($0.dropFirst(4)) }
        var unique = Set(actionTags)
        
        for key in tagProfiles.keys {
            if key.hasPrefix("tag:") {
                unique.insert(String(key.dropFirst(4)))
            }
        }
        
        return Array(unique).sorted()
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
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(filteredTags, id: \.self) { tag in
                        let isSelected = sidebarSelection.contains(.tag(tag))
                        #if os(iOS)
                        Button(action: {
                            sidebarSelection = [.tag(tag)]
                        }) {
                            TagGalleryItemView(
                                tag: tag,
                                assetsCount: assets.filter { $0.tags.contains("tag:\(tag)") }.count,
                                isSelected: isSelected
                            )
                        }
                        .buttonStyle(.plain)
                        #else
                        Button(action: {
                            toggleSelection(item: .tag(tag))
                        }) {
                            TagGalleryItemView(
                                tag: tag,
                                assetsCount: assets.filter { $0.tags.contains("tag:\(tag)") }.count,
                                isSelected: isSelected
                            )
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Tags Gallery")
        .toolbar {
#if !os(iOS)
            let selectedTagsCount = sidebarSelection.filter { item in
                if case .tag = item { return true }
                return false
            }.count
            
            if selectedTagsCount > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        sidebarSelection.remove(.tagGallery)
                    }) {
                        Text("View Matches")
                            .bold()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
#endif
        }
        .onAppear {
            fetchProfiles()
        }
        .onChange(of: assets.count) { old, new in
            fetchProfiles()
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
    
    private func fetchProfiles() {
        guard let url = libraryURL else { return }
        do {
            let store = try LibraryStore(at: url)
            let allProfiles = try store.fetchAllEntityProfiles()
            for profile in allProfiles {
                if profile.id.hasPrefix("tag:") {
                    tagProfiles[profile.id] = profile
                }
            }
        } catch {
            print("Failed to fetch tag profiles: \(error)")
        }
    }
}

struct TagGalleryItemView: View {
    let tag: String
    let assetsCount: Int
    let isSelected: Bool
    
    var body: some View {
        HStack {
            Image(systemName: "tag.fill")
                .foregroundColor(.green)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(tag)
                    .font(.headline)
                    .lineLimit(1)
                
                Text("\(assetsCount) Video\(assetsCount == 1 ? "" : "s")")
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
