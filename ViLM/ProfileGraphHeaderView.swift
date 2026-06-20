import SwiftUI
import LibraryCore

struct ProfileGraphHeaderView: View {
    let filteredAssets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let currentSelection: SidebarItem
    let libraryURL: URL?
    
    @State private var entityProfile: EntityProfile?
    @State private var isShowingEditor = false
    
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
    
    private func currentSelectionName(for type: String) -> String? {
        switch currentSelection {
        case .studio(let name) where type == "studio": return name
        case .actor(let name) where type == "actor": return name
        case .tag(let name) where type == "tag": return name
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
                if isEditableEntity {
                    Button("Edit Bio") {
                        isShowingEditor = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            if let profile = entityProfile {
                HStack(alignment: .top, spacing: 16) {
                    if let photoUrl = profile.photoUrl, let url = URL(string: photoUrl) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        if let bio = profile.bio {
                            Text(bio).font(.body)
                        }
                        if let homePage = profile.homePage, let url = URL(string: homePage) {
                            Link("Visit Website", destination: url)
                                .font(.callout)
                        }
                    }
                }
            }
            
            if !relatedStudios.isEmpty {
                tagSection(title: "Studios", items: relatedStudios, color: .purple) { item in
                    sidebarSelection = [.studio(item)]
                }
            }
            if !relatedActors.isEmpty {
                tagSection(title: "Co-Actors", items: relatedActors, color: .blue) { item in
                    sidebarSelection = [.actor(item)]
                }
            }
            if !relatedTags.isEmpty {
                tagSection(title: "Tags", items: relatedTags, color: .green) { item in
                    sidebarSelection = [.tag(item)]
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
        .onAppear { fetchProfile() }
        .onChange(of: currentSelection) { _ in fetchProfile() }
        .sheet(isPresented: $isShowingEditor) {
            if let id = currentEntityId {
                EntityProfileEditorView(entityId: id, profile: entityProfile, onSave: saveProfile)
            }
        }
    }
    
    private var titleText: String {
        switch currentSelection {
        case .actor(let name): return "\(name)'s Profile Graph"
        case .studio(let name): return "\(name) Studio Graph"
        case .tag(let name): return "Tag Graph: \(name)"
        case .allAssets: return ""
        }
    }
    
    private var currentEntityId: String? {
        switch currentSelection {
        case .actor(let name): return "actor:\(name)"
        case .studio(let name): return "studio:\(name)"
        case .tag(let name): return "tag:\(name)"
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
    
    private func tagSection(title: String, items: [String], color: Color, onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundColor(.secondary).fontWeight(.medium)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Button(action: { onSelect(item) }) {
                        Text(item)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(color.opacity(0.15))
                            .foregroundColor(color)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
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
        }
    }
}
