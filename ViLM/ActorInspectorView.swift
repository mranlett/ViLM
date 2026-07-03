import SwiftUI
import LibraryCore

struct ActorInspectorView: View {
    let selectedActors: [String]
    let libraryURL: URL?
    @Binding var gridRefreshID: UUID
    
    @State private var singleProfile: EntityProfile?
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                if selectedActors.count == 1, let profile = singleProfile {
                    EntityProfileEditorView(
                        libraryURL: libraryURL,
                        entityId: "actor:\(selectedActors[0])",
                        profile: profile,
                        onSave: { _ in
                            gridRefreshID = UUID()
                        }
                    )
                } else if selectedActors.count > 1 {
                    BatchEntityProfileEditorView(
                        libraryURL: libraryURL,
                        entityIds: selectedActors.map { "actor:\($0)" },
                        onSave: { _ in
                            gridRefreshID = UUID()
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "No Actor Profile",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                }
            }
        }
        .onAppear { fetchProfile() }
        .onChange(of: selectedActors) { _, _ in fetchProfile() }
    }
    
    private func fetchProfile() {
        guard selectedActors.count == 1, let url = libraryURL else {
            isLoading = false
            return
        }
        
        isLoading = true
        Task {
            do {
                let store = try LibraryStore(at: url)
                let profile = try store.fetchEntityProfile(for: "actor:\(selectedActors[0])")
                await MainActor.run {
                    self.singleProfile = profile ?? EntityProfile(id: "actor:\(selectedActors[0])")
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.singleProfile = EntityProfile(id: "actor:\(selectedActors[0])")
                    self.isLoading = false
                }
            }
        }
    }
}
