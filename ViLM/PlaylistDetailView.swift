// PlaylistDetailView.swift
// A playlist's page: its videos in MANUAL order (drag to reorder — the
// feature's defining trait), swipe/Edit to remove, rename/delete, Shuffle,
// and an Add Videos picker. Entries whose video isn't in the current
// open-library union render as "unavailable" (never auto-deleted — reattach
// the owning library and they're back); "Remove Unavailable" is the explicit
// cleanup. All writes go to the PRIMARY library, where playlists live.

import SwiftUI
import LibraryCore

struct PlaylistDetailView: View {
    let playlistID: String
    /// The session's asset union — entries resolve against this.
    let assets: [Asset]
    /// Plays a video with auto-play (the quick-action mechanism).
    let onPlay: (Asset.ID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var playlist: Playlist?
    @State private var items: [PlaylistItem] = []
    @State private var isShowingAddPicker = false
    @State private var isShowingRename = false
    @State private var renameText = ""
    @State private var isShowingDeleteConfirm = false
    @State private var isShowingHelp = false

    private struct Entry: Identifiable {
        let item: PlaylistItem
        let asset: Asset?          // nil = unavailable (library not open)
        var id: String { item.assetId }
    }

    private var entries: [Entry] {
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id.uuidString, $0) })
        return items.map { Entry(item: $0, asset: byID[$0.assetId]) }
    }

    private var availableAssets: [Asset] { entries.compactMap(\.asset) }
    private var unavailableCount: Int { entries.count - availableAssets.count }
    /// Ordered available ids — the prev/next context for pushed details.
    private var availableIDs: [Asset.ID] { availableAssets.map(\.id) }

    var body: some View {
        List {
            if unavailableCount > 0 {
                Section {
                    Label(
                        "\(unavailableCount) video\(unavailableCount == 1 ? " is" : "s are") in a library that isn't open right now.",
                        systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            Section {
                ForEach(entries) { entry in
                    row(for: entry)
                }
                .onMove(perform: moveEntries)
                .onDelete(perform: deleteEntries)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Videos Yet", systemImage: "list.and.film")
                } description: {
                    Text("Add videos here, or select them anywhere and choose “Add to Playlist”.")
                } actions: {
                    Button("Add Videos…") { isShowingAddPicker = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isShowingAddPicker = true
                    } label: {
                        Label("Add Videos…", systemImage: "plus")
                    }
                    Button {
                        if let pick = availableAssets.randomElement() { onPlay(pick.id) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .disabled(availableAssets.isEmpty)
                    Button {
                        renameText = playlist?.name ?? ""
                        isShowingRename = true
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    if unavailableCount > 0 {
                        Button {
                            removeUnavailable()
                        } label: {
                            Label("Remove Unavailable (\(unavailableCount))", systemImage: "eye.slash")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        isShowingDeleteConfirm = true
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Playlist actions")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    isShowingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Help")
                .accessibilityLabel("Help")
            }
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView(initialTopicID: HelpContent.playlists.id)
        }
        .alert("Rename Playlist", isPresented: $isShowingRename) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(playlist?.name ?? "")”? The videos themselves are not touched — a playlist is only a list.",
            isPresented: $isShowingDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) { deletePlaylist() }
        }
        .sheet(isPresented: $isShowingAddPicker) {
            PlaylistAddPickerView(
                candidates: assets.filter { asset in
                    !items.contains { $0.assetId == asset.id.uuidString }
                },
                onAdd: { ids in addVideos(ids) }
            )
        }
        .onAppear { reload() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        if let asset = entry.asset {
            NavigationLink(value: AppRoute.asset(asset.id, context: availableIDs)) {
                HStack(spacing: 12) {
                    VideoThumbnailView(asset: asset, libraryURL: LibrarySession.shared.url(for: asset.id))
                        .frame(width: 80, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.videoName ?? asset.fileName)
                            .font(.callout)
                            .lineLimit(2)
                        if LibrarySession.shared.isFederated,
                           let owner = LibrarySession.shared.url(for: asset.id) {
                            Text(LibrarySession.shared.shortLabel(for: owner))
                                .font(.caption2)
                                .foregroundColor(.teal)
                        }
                    }
                    Spacer()
                    Button {
                        onPlay(asset.id)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Play \(asset.videoName ?? asset.fileName)")
                }
            }
        } else {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 80, height: 45)
                    .overlay(Image(systemName: "eye.slash").foregroundColor(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unavailable")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text("Its library isn't open — attach it to see this video.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Store operations (primary library)

    private func primaryStore() throws -> LibraryStore {
        guard let url = LibrarySession.shared.primaryURL else { throw CocoaError(.fileNoSuchFile) }
        return try LibraryStore(at: url)
    }

    private func reload() {
        do {
            let store = try primaryStore()
            playlist = try store.fetchAllPlaylists().first { $0.id == playlistID }
            items = try store.fetchPlaylistItems(playlistId: playlistID)
        } catch {
            print("Failed to load playlist: \(error)")
        }
    }

    private func announceChange() {
        NotificationCenter.default.post(name: NSNotification.Name("ReloadPlaylists"), object: nil)
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            let orderedIds = reordered.compactMap { UUID(uuidString: $0.assetId) }
            try primaryStore().reorderPlaylist(id: playlistID, orderedAssetIds: orderedIds)
            items = reordered
            announceChange()
        } catch {
            AppErrorReporter.report("Couldn't reorder the playlist: \(error.localizedDescription)")
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        let ids = offsets.compactMap { UUID(uuidString: items[$0].assetId) }
        do {
            try primaryStore().removeFromPlaylist(id: playlistID, assetIds: ids)
            reload()
            announceChange()
        } catch {
            AppErrorReporter.report("Couldn't remove from the playlist: \(error.localizedDescription)")
        }
    }

    private func addVideos(_ ids: [Asset.ID]) {
        do {
            try primaryStore().addToPlaylist(id: playlistID, assetIds: ids)
            reload()
            announceChange()
        } catch {
            AppErrorReporter.report("Couldn't add to the playlist: \(error.localizedDescription)")
        }
    }

    private func rename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try primaryStore().renamePlaylist(id: playlistID, to: name)
            reload()
            announceChange()
        } catch {
            AppErrorReporter.report("Couldn't rename the playlist: \(error.localizedDescription)")
        }
    }

    private func removeUnavailable() {
        do {
            try primaryStore().prunePlaylistEntries(
                playlistId: playlistID, keeping: Set(assets.map(\.id)))
            reload()
            announceChange()
        } catch {
            AppErrorReporter.report("Couldn't clean up the playlist: \(error.localizedDescription)")
        }
    }

    private func deletePlaylist() {
        do {
            try primaryStore().deletePlaylist(id: playlistID)
            announceChange()
            dismiss()
        } catch {
            AppErrorReporter.report("Couldn't delete the playlist: \(error.localizedDescription)")
        }
    }
}

// MARK: - Add Videos picker

/// A lightweight searchable multi-select over the videos not yet in the
/// playlist. Adds append at the end, in the order shown.
struct PlaylistAddPickerView: View {
    let candidates: [Asset]
    let onAdd: ([Asset.ID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selected: Set<Asset.ID> = []

    private var filtered: [Asset] {
        let sorted = candidates.sorted {
            ($0.videoName ?? $0.fileName).localizedStandardCompare($1.videoName ?? $1.fileName) == .orderedAscending
        }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            ($0.videoName ?? $0.fileName).localizedCaseInsensitiveContains(searchText)
                || $0.fileName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { asset in
                Button {
                    if selected.contains(asset.id) {
                        selected.remove(asset.id)
                    } else {
                        selected.insert(asset.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selected.contains(asset.id) ? .accentColor : .secondary)
                        VideoThumbnailView(asset: asset, libraryURL: LibrarySession.shared.url(for: asset.id))
                            .frame(width: 64, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(asset.videoName ?? asset.fileName)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search videos")
            .navigationTitle("Add Videos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") {
                        // Preserve display order for predictable appending.
                        onAdd(filtered.filter { selected.contains($0.id) }.map(\.id))
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
        #endif
    }
}
