// Playlist.swift
// Hand-picked, manually ORDERED lists of videos — the complement to
// SmartCollection (saved criteria): a playlist contains exactly the videos
// the user put in it, in the order they arranged, and future videos never
// join automatically. Stored in the primary library (same rule as
// collections); see plans/playlists.md.

import Foundation
import GRDB

public struct Playlist: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public let id: String
    public var name: String
    public var createdAt: Date

    public static let databaseTableName = "playlists"

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// One playlist membership. `assetId` deliberately carries NO foreign key:
/// in a multi-library session a playlist may reference a video living in an
/// ATTACHED library, whose row exists in a different database entirely.
/// Entries resolve against the open-library union at display time; one whose
/// video isn't currently open renders as "unavailable" and is never
/// auto-deleted (reattach the library and it's back).
public struct PlaylistItem: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public var playlistId: String
    public var assetId: String
    /// Manual ordering — the playlist's defining feature. Appends go to the
    /// end; reordering rewrites positions.
    public var position: Int
    public var addedAt: Date

    public static let databaseTableName = "playlist_items"

    public init(playlistId: String, assetId: String, position: Int, addedAt: Date = Date()) {
        self.playlistId = playlistId
        self.assetId = assetId
        self.position = position
        self.addedAt = addedAt
    }
}
