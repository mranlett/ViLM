// ActorInspectorView.swift
// Detail-pane content when multiple actors are selected in the split view:
// hosts the single-profile editor (one actor) or the batch profile editor
// (several), persisting saves back through LibraryStore.

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
                        embedsInNavigationStack: false,
                        onSave: { profile in
                            // The editor doesn't persist — that's the
                            // caller's job. Skipping this silently discards
                            // the user's edits.
                            if libraryURL != nil {
                                do {
                                    // Writes land in the profile's OWNING library.
                                    let store = try LibrarySession.shared.store(forProfile: profile.id)
                                    try store.saveEntityProfile(profile)
                                } catch {
                                    print("Failed to save profile: \(error)")
                                    AppErrorReporter.report("Couldn't save the profile: \(error.localizedDescription)")
                                }
                            }
                            gridRefreshID = UUID()
                            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
                        }
                    )
                } else if selectedActors.count > 1 {
                    BatchEntityProfileEditorView(
                        libraryURL: libraryURL,
                        entityIds: selectedActors.map { "actor:\($0)" },
                        onSave: { _ in
                            gridRefreshID = UUID()
                            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
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
        .navigationTitle("Actor Profile")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleFullScreen"), object: nil)
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Toggle Full Screen")
            }
        }
    }
    
    private func fetchProfile() {
        guard selectedActors.count == 1, let url = libraryURL else {
            isLoading = false
            return
        }
        
        isLoading = true
        Task {
            do {
                // This pane IS the edit surface — load the owning library's
                // raw copy, not the merged view (see ProfileGraphHeaderView).
                _ = url
                let entityId = "actor:\(selectedActors[0])"
                let store = try LibrarySession.shared.store(forProfile: entityId)
                let profile = try store.fetchEntityProfile(for: entityId)
                await MainActor.run {
                    self.singleProfile = profile ?? EntityProfile(id: "actor:\(selectedActors[0])")
                    self.isLoading = false
                }
            } catch {
                // A FAILED fetch must not fabricate a blank profile — the
                // editor would show empty fields over a real record, and
                // saving would overwrite the actor's bio/photos/AKAs with
                // blanks. Show the unavailable state instead.
                print("Failed to fetch actor profile: \(error)")
                await MainActor.run {
                    self.singleProfile = nil
                    self.isLoading = false
                }
            }
        }
    }
}
