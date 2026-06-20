import SwiftUI
import LibraryCore

struct ActorGridView: View {
    let assets: [Asset]
    @Binding var sidebarSelection: Set<SidebarItem>
    let libraryURL: URL?
    
    @State private var actorProfiles: [String: EntityProfile] = [:]
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        return Array(Set(actorTags)).sorted()
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 20) {
                ForEach(allUniqueActors, id: \.self) { actor in
                    ActorGridItemView(
                        actor: actor,
                        profile: actorProfiles["actor:\(actor)"],
                        assetsCount: assets.filter { $0.actors.contains(actor) }.count
                    )
                    .onTapGesture {
                        sidebarSelection = [.actor(actor)]
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Actors Gallery")
        .onAppear {
            fetchProfiles()
        }
        .onChange(of: assets.count) { _ in
            fetchProfiles()
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
    
    var body: some View {
        VStack {
            if let photoUrlString = profile?.photoUrl, let url = URL(string: photoUrlString) {
                AsyncImage(url: url) { image in
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
        .background(Color.secondary.opacity(0.05))
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
