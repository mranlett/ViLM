// LibraryStore+Collections.swift
// Playlists and scene markers: the two things a person curates by hand.
//
// Split out of `LibraryStore.swift` on 2026-08-07. Nothing changed in the move.
//
// ⭐ Together because they share a property nothing else in the store has:
// both are ORDERED, and both are the operator's own arrangement rather than
// anything derived from the files. A playlist has a `position` column and a
// marker has a timecode, and in each case the order IS the data — which is why
// neither can be expressed as one of the graph's bare-pair edge tables.

import Foundation
import GRDB

extension LibraryStore {

    // MARK: - Playlists

    public func fetchAllPlaylists() throws -> [Playlist] {
        try dbQueue.read { db in
            try fetchAllPlaylists(in: db)
        }
    }

    func fetchAllPlaylists(in db: Database) throws -> [Playlist] {
        try Playlist.order(Column("createdAt").asc).fetchAll(db)
    }

    /// Items in their manual order.
    public func fetchPlaylistItems(playlistId: String) throws -> [PlaylistItem] {
        try dbQueue.read { db in
            try fetchPlaylistItems(playlistId: playlistId, in: db)
        }
    }

    func fetchPlaylistItems(playlistId: String, in db: Database) throws -> [PlaylistItem] {
        try PlaylistItem
            .filter(Column("playlistId") == playlistId)
            .order(Column("position").asc)
            .fetchAll(db)
    }

    @discardableResult
    public func createPlaylist(named name: String) throws -> Playlist {
        let playlist = Playlist(name: name)
        try dbQueue.write { db in
            try playlist.insert(db)
        }
        return playlist
    }

    public func renamePlaylist(id: String, to name: String) throws {
        try dbQueue.write { db in
            if var playlist = try Playlist.fetchOne(db, key: id) {
                playlist.name = name
                try playlist.update(db)
            }
        }
    }

    /// Removes the playlist and (via cascade) its memberships. The videos
    /// themselves are untouched — a playlist is only a list.
    public func deletePlaylist(id: String) throws {
        try dbQueue.write { db in
            _ = try Playlist.deleteOne(db, key: id)
        }
    }

    /// Appends `assetIds` that aren't already members, in the given order, at
    /// the END of the playlist (one transaction). Duplicates are silently
    /// skipped so "Select All → Add" is safely repeatable. Returns how many
    /// were actually added.
    @discardableResult
    public func addToPlaylist(id: String, assetIds: [Asset.ID]) throws -> Int {
        try performInTransaction { db in
            let existing = Set(try fetchPlaylistItems(playlistId: id, in: db).map(\.assetId))
            let maxPosition = try Int.fetchOne(
                db, sql: "SELECT MAX(position) FROM playlist_items WHERE playlistId = ?",
                arguments: [id]) ?? -1
            var next = maxPosition + 1
            var added = 0
            for assetId in assetIds where !existing.contains(assetId.uuidString) {
                try PlaylistItem(playlistId: id, assetId: assetId.uuidString, position: next).insert(db)
                next += 1
                added += 1
            }
            return added
        }
    }

    public func removeFromPlaylist(id: String, assetIds: [Asset.ID]) throws {
        let idStrings = assetIds.map(\.uuidString)
        try dbQueue.write { db in
            _ = try PlaylistItem
                .filter(Column("playlistId") == id)
                .filter(idStrings.contains(Column("assetId")))
                .deleteAll(db)
        }
    }

    /// Persists a complete manual re-ordering: positions are rewritten to the
    /// index of each entry in `orderedAssetIds` (one transaction). Members
    /// not mentioned keep their rows but sort after the mentioned ones.
    public func reorderPlaylist(id: String, orderedAssetIds: [Asset.ID]) throws {
        try performInTransaction { db in
            for (index, assetId) in orderedAssetIds.enumerated() {
                try db.execute(
                    sql: "UPDATE playlist_items SET position = ? WHERE playlistId = ? AND assetId = ?",
                    arguments: [index, id, assetId.uuidString])
            }
        }
    }

    /// "Remove Unavailable": drops entries whose videos aren't in
    /// `availableIds` (the current open-library union). Explicit user action
    /// only — dangling entries are otherwise kept, since detaching a library
    /// makes its videos unavailable without making them gone.
    public func prunePlaylistEntries(playlistId: String, keeping availableIds: Set<Asset.ID>) throws {
        let keep = Set(availableIds.map(\.uuidString))
        try dbQueue.write { db in
            let items = try fetchPlaylistItems(playlistId: playlistId, in: db)
            for item in items where !keep.contains(item.assetId) {
                try db.execute(
                    sql: "DELETE FROM playlist_items WHERE playlistId = ? AND assetId = ?",
                    arguments: [item.playlistId, item.assetId])
            }
        }
    }

    /// Removes a deleted video's memberships across all of THIS library's
    /// playlists (the delete path's cleanup; cross-library dangling entries
    /// are tolerated by display instead).
    func removePlaylistEntries(assetId: Asset.ID, in db: Database) throws {
        _ = try PlaylistItem
            .filter(Column("assetId") == assetId.uuidString)
            .deleteAll(db)
    }

    // MARK: - Scene Markers

    public func fetchSceneMarkers(for assetId: Asset.ID) throws -> [SceneMarker] {
        try dbQueue.read { db in
            try fetchSceneMarkers(for: assetId, in: db)
        }
    }

    func fetchSceneMarkers(for assetId: Asset.ID, in db: Database) throws -> [SceneMarker] {
        try SceneMarker
            .filter(Column("asset_id") == assetId.uuidString)
            .order(Column("timestamp_seconds").asc)
            .fetchAll(db)
    }

    public func saveSceneMarker(_ marker: SceneMarker) throws {
        try dbQueue.write { db in
            try saveSceneMarker(marker, in: db)
        }
    }

    func saveSceneMarker(_ marker: SceneMarker, in db: Database) throws {
        try marker.save(db)
    }

    public func deleteSceneMarker(id: SceneMarker.ID) throws {
        try dbQueue.write { db in
            try deleteSceneMarker(id: id, in: db)
        }
    }

    func deleteSceneMarker(id: SceneMarker.ID, in db: Database) throws {
        _ = try SceneMarker.deleteOne(db, key: id.uuidString)
    }
    
    public func updateAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try updateAsset(asset, in: db)
        }
    }

    func updateAsset(_ asset: Asset, in db: Database) throws {
        try asset.update(db)
    }

    /// Inserts a fully-populated asset row (every column), unlike the
    /// scanner's `saveAsset` which is an INSERT-OR-IGNORE that only writes the
    /// handful of columns a freshly-discovered file has. Used by the video
    /// transfer tool to persist a moved asset's complete metadata in one shot.
    public func insertAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try insertAsset(asset, in: db)
        }
    }

    func insertAsset(_ asset: Asset, in db: Database) throws {
        try asset.insert(db)
    }

}
