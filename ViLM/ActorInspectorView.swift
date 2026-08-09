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
    /// The LOCAL ids the selected names resolve to.
    ///
    /// ⭐ Carried rather than rebuilt as `"actor:\(name)"` at each use. The
    /// editor writes through the id it is handed, so after the re-key a
    /// name-form id would have it saving to a row that does not exist.
    @State private var resolvedEntityIds: [String] = []
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                if selectedActors.count == 1, let profile = singleProfile {
                    EntityProfileEditorView(
                        libraryURL: libraryURL,
                        entityId: resolvedEntityIds.first ?? "actor:\(selectedActors[0])",
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
                        entityIds: resolvedEntityIds.isEmpty
                            ? selectedActors.map { "actor:\($0)" }
                            : resolvedEntityIds,
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
                // ⭐ Resolved by NAME. The selection carries names, and the
                // id is whatever this library keys that name under.
                let name = selectedActors[0]
                let store = try LibrarySession.shared.store(forProfile: "actor:\(name)")
                let profile = try store.fetchEntityProfile(named: name, type: "actor")

                // ⚠️ Neither of these may THROW. A failure here would land in
                // the catch below and show the unavailable state even though
                // the profile above was fetched successfully — discarding a
                // real record over a stand-in that was only a fallback.
                //
                // An actor with no row yet gets a stand-in keyed the way this
                // library keys things, so a first save lands correctly.
                let standIn = (try? store.newEntityProfile(named: name, type: "actor"))
                    ?? EntityProfile(id: "actor:\(name)", entityType: "actor",
                                     displayName: name)
                let resolved = selectedActors.map { each -> String in
                    // ⚠️ The name form is the fallback, and is also a valid
                    // argument to `store(forProfile:)` — that lookup resolves
                    // a legacy name-form id through the node's identity.
                    let nameForm = "actor:\(each)"
                    guard let owner = try? LibrarySession.shared.store(forProfile: nameForm),
                          let resolvedId = try? owner.entityId(named: each, type: "actor")
                    else { return nameForm }
                    return resolvedId ?? nameForm
                }
                await MainActor.run {
                    self.singleProfile = profile ?? standIn
                    self.resolvedEntityIds = resolved
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
