import SwiftUI
import LibraryCore

struct ActorGridView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let libraryURL: URL?
    
    @State private var actorProfiles: [String: EntityProfile] = [:]
    @State private var alphaFilter: Character? = nil
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        return Array(Set(actorTags)).sorted()
    }
    
    var filteredActors: [String] {
        guard let letter = alphaFilter else { return allUniqueActors }
        return allUniqueActors.filter { $0.uppercased().hasPrefix(String(letter)) }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AlphaPickerView(filter: $alphaFilter)
                    .padding(.horizontal)
                    .padding(.bottom)
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 20) {
                    ForEach(filteredActors, id: \.self) { actor in
                        let isSelected = sidebarSelection.contains(.actor(actor))
                        ActorGridItemView(
                            actor: actor,
                            profile: actorProfiles["actor:\(actor)"],
                            assetsCount: assets.filter { $0.actors.contains(actor) }.count,
                            isSelected: isSelected,
                            libraryURL: libraryURL
                        )
                        .onTapGesture {
                            toggleSelection(item: .actor(actor))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Actors Gallery")
        .toolbar {
            let selectedActorsCount = sidebarSelection.filter { item in
                if case .actor = item { return true }
                return false
            }.count
            
            if selectedActorsCount > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        sidebarSelection.remove(.actorGallery)
                    }) {
                        Text("View Matches")
                            .bold()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            fetchProfiles()
        }
        .onChange(of: assets.count) { _ in
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
            for actor in allUniqueActors {
                if let profile = try store.fetchEntityProfile(for: "actor:\(actor)") {
                    actorProfiles["actor:\(actor)"] = profile
                }
            }
        } catch {
            print("Failed to fetch actor profiles: \(error)")
        }
    }
}

struct ActorGridItemView: View {
    let actor: String
    let profile: EntityProfile?
    let assetsCount: Int
    let isSelected: Bool
    let libraryURL: URL?
    
    var body: some View {
        VStack {
            if let photoUrlString = profile?.photoUrl {
                ProfileImageView(libraryURL: libraryURL, entityId: "actor:\(actor)", photoUrl: photoUrlString) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .shadow(radius: 4)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                    )
            }
            
            Text(actor)
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 8)
            
            Text("\(assetsCount) Video\(assetsCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.05))
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
