import SwiftUI
import LibraryCore

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let assets: [Asset]
    let onOpenLibrary: () -> Void
    
    // MARK: - Computed Properties
    
    var allUniqueActors: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actorTags = allTags.filter { $0.hasPrefix("actor:") }.map { String($0.dropFirst(6)) }
        return Array(Set(actorTags)).sorted()
    }
    
    var allUniqueTags: [String] {
        let allTags = assets.flatMap { $0.tags }
        let actionTags = allTags.filter { $0.hasPrefix("tag:") }.map { String($0.dropFirst(4)) }
        return Array(Set(actionTags)).sorted()
    }
    
    // Stats for progress tracking
    private var reviewProgress: Double {
        guard !assets.isEmpty else { return 0 }
        let reviewed = assets.filter { $0.status == .reviewed }.count
        return Double(reviewed) / Double(assets.count)
    }

    private var unreviewedCount: Int {
        assets.filter { $0.status == .unreviewed }.count
    }
    
    // MARK: - Body
    
    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Button(action: onOpenLibrary) {
                    Label("Open Library", systemImage: "folder.badge.plus")
                }
                
                HStack {
                    Label("All Assets", systemImage: "play.rectangle.on.rectangle")
                    Spacer()
                    if unreviewedCount > 0 {
                        Text("\(unreviewedCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                .tag(SidebarItem.allAssets)
            }
            
            Section("Actors") {
                ForEach(allUniqueActors, id: \.self) { actor in
                    Label(actor, systemImage: "person").tag(SidebarItem.actor(actor))
                }
            }
            
            Section("Tags") {
                ForEach(allUniqueTags, id: \.self) { tag in
                    Label(tag, systemImage: "tag").tag(SidebarItem.tag(tag))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            progressFooter
        }
        .navigationTitle("ViLM")
    }
    
    // MARK: - Progress Footer
    private var progressFooter: some View {
        VStack(spacing: 8) {
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
