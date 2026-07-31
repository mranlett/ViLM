// PlaylistMenus.swift
// The shared "Add to Playlist" machinery used by every entry point: the
// selection bottom bar (search → select → add flow), the video-card context
// menus (iOS long-press, macOS right-click), and Video Details. One menu-items
// view + one "New Playlist" prompt modifier + the store actions, so all entry
// points behave identically. Playlists live in the PRIMARY library.

import SwiftUI
import LibraryCore

@MainActor
enum PlaylistActions {
    static func fetchPlaylists() -> [Playlist] {
        guard let url = LibrarySession.shared.primaryURL else { return [] }
        return (try? LibraryStore(at: url).fetchAllPlaylists()) ?? []
    }

    /// Adds (dedupe + append) and gives toast feedback either way.
    static func add(_ assetIDs: [Asset.ID], to playlist: Playlist) {
        guard let url = LibrarySession.shared.primaryURL else { return }
        do {
            let added = try LibraryStore(at: url).addToPlaylist(id: playlist.id, assetIds: assetIDs)
            NotificationCenter.default.post(name: NSNotification.Name("ReloadPlaylists"), object: nil)
            if added == 0 {
                AppErrorReporter.report("Already in “\(playlist.name)”.")
            } else {
                AppErrorReporter.report("Added \(added) video\(added == 1 ? "" : "s") to “\(playlist.name)”.")
            }
        } catch {
            AppErrorReporter.report("Couldn't add to “\(playlist.name)”: \(error.localizedDescription)")
        }
    }

    static func createAndAdd(named name: String, assetIDs: [Asset.ID]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = LibrarySession.shared.primaryURL else { return }
        do {
            let playlist = try LibraryStore(at: url).createPlaylist(named: trimmed)
            add(assetIDs, to: playlist)
        } catch {
            AppErrorReporter.report("Couldn't create the playlist: \(error.localizedDescription)")
        }
    }
}

/// The items INSIDE an "Add to Playlist" menu: one button per existing
/// playlist, then "New Playlist…" (which hands off to the host's prompt via
/// `onNewPlaylist`, since menus can't host text fields).
struct AddToPlaylistMenuItems: View {
    let assetIDs: [Asset.ID]
    let onNewPlaylist: () -> Void

    var body: some View {
        let playlists = PlaylistActions.fetchPlaylists()
        return Group {
            ForEach(playlists) { playlist in
                Button {
                    PlaylistActions.add(assetIDs, to: playlist)
                } label: {
                    Label(playlist.name, systemImage: "list.and.film")
                }
            }
            if !playlists.isEmpty { Divider() }
            Button {
                onNewPlaylist()
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
        }
    }
}

/// Host-side "New Playlist" name prompt. Set the binding to the ids you want
/// added; the alert shows, creates, adds, and clears it.
struct NewPlaylistPrompt: ViewModifier {
    @Binding var pendingAssetIDs: [Asset.ID]?
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert(
            "New Playlist",
            isPresented: Binding(
                get: { pendingAssetIDs != nil },
                set: { if !$0 { pendingAssetIDs = nil } })
        ) {
            TextField("Name", text: $name)
            Button("Create & Add") {
                if let ids = pendingAssetIDs {
                    PlaylistActions.createAndAdd(named: name, assetIDs: ids)
                }
                name = ""
                pendingAssetIDs = nil
            }
            Button("Cancel", role: .cancel) {
                name = ""
                pendingAssetIDs = nil
            }
        } message: {
            Text("Playlists keep exactly the videos you add, in your order.")
        }
    }
}
