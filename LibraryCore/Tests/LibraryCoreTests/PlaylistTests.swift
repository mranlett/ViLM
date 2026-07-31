import XCTest
@testable import LibraryCore

/// Playlists: hand-picked ordered lists (schema v16). CRUD, the append/dedupe
/// contract, manual reordering, dangling-entry tolerance (no FK on assetId by
/// design — cross-library references), the delete-path prune, and the
/// restore-merge union.
final class PlaylistTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    func testCreateRenameDeleteRoundTrip() throws {
        let playlist = try store.createPlaylist(named: "Road Trip")
        XCTAssertEqual(try store.fetchAllPlaylists().map(\.name), ["Road Trip"])

        try store.renamePlaylist(id: playlist.id, to: "Long Road Trip")
        XCTAssertEqual(try store.fetchAllPlaylists().map(\.name), ["Long Road Trip"])

        try store.deletePlaylist(id: playlist.id)
        XCTAssertTrue(try store.fetchAllPlaylists().isEmpty)
    }

    func testAddAppendsInOrderAndSkipsDuplicates() throws {
        let playlist = try store.createPlaylist(named: "P")
        let a = UUID(), b = UUID(), c = UUID()

        XCTAssertEqual(try store.addToPlaylist(id: playlist.id, assetIds: [a, b]), 2)
        // Re-adding b is a silent no-op; c appends at the END.
        XCTAssertEqual(try store.addToPlaylist(id: playlist.id, assetIds: [b, c]), 1)

        let items = try store.fetchPlaylistItems(playlistId: playlist.id)
        XCTAssertEqual(items.map(\.assetId), [a, b, c].map(\.uuidString), "append order preserved")
        XCTAssertEqual(items.map(\.position), [0, 1, 2])
    }

    func testReorderPersistsTheNewSequence() throws {
        let playlist = try store.createPlaylist(named: "P")
        let a = UUID(), b = UUID(), c = UUID()
        try store.addToPlaylist(id: playlist.id, assetIds: [a, b, c])

        try store.reorderPlaylist(id: playlist.id, orderedAssetIds: [c, a, b])

        XCTAssertEqual(try store.fetchPlaylistItems(playlistId: playlist.id).map(\.assetId),
                       [c, a, b].map(\.uuidString))
    }

    func testRemoveAndCascadeDelete() throws {
        let playlist = try store.createPlaylist(named: "P")
        let a = UUID(), b = UUID()
        try store.addToPlaylist(id: playlist.id, assetIds: [a, b])

        try store.removeFromPlaylist(id: playlist.id, assetIds: [a])
        XCTAssertEqual(try store.fetchPlaylistItems(playlistId: playlist.id).map(\.assetId), [b.uuidString])

        // Deleting the playlist cascades its memberships away.
        try store.deletePlaylist(id: playlist.id)
        XCTAssertTrue(try store.fetchPlaylistItems(playlistId: playlist.id).isEmpty)
    }

    func testDanglingEntriesAreKeptUntilExplicitPrune() throws {
        // No FK on assetId BY DESIGN: an entry may reference an attached
        // library's video. It must survive normal operation and go away only
        // via the explicit "Remove Unavailable" prune.
        let playlist = try store.createPlaylist(named: "P")
        let local = UUID(), foreign = UUID()
        try store.addToPlaylist(id: playlist.id, assetIds: [local, foreign])

        XCTAssertEqual(try store.fetchPlaylistItems(playlistId: playlist.id).count, 2,
                       "an unresolvable entry is not silently dropped")

        try store.prunePlaylistEntries(playlistId: playlist.id, keeping: [local])
        XCTAssertEqual(try store.fetchPlaylistItems(playlistId: playlist.id).map(\.assetId),
                       [local.uuidString])
    }

    func testDeletingAVideoRemovesItsMembershipsInThisLibrary() throws {
        // The hardened delete removes the row AND its playlist memberships in
        // one transaction (same-library case; cross-library stays tolerated).
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")
        try store.insertAsset(asset)
        try Data([1]).write(to: libraryURL.appendingPathComponent("a.mp4"))
        let p1 = try store.createPlaylist(named: "One")
        let p2 = try store.createPlaylist(named: "Two")
        try store.addToPlaylist(id: p1.id, assetIds: [asset.id])
        try store.addToPlaylist(id: p2.id, assetIds: [asset.id])

        try VideoTransferService().deleteVideoAndArtifacts(asset, in: libraryURL, toTrash: false)

        XCTAssertTrue(try store.fetchPlaylistItems(playlistId: p1.id).isEmpty)
        XCTAssertTrue(try store.fetchPlaylistItems(playlistId: p2.id).isEmpty)
        XCTAssertTrue(try store.fetchAllAssets().isEmpty)
    }

    func testRestoreMergeUnionsPlaylists() throws {
        // Backup holds playlist P with [a, b]. After the backup: b removed
        // and local-only c appended, plus a brand-new playlist Q. Merging the
        // backup keeps the destination's order, re-appends the archive-only b
        // at the end, and restores Q whole.
        let a = UUID(), b = UUID(), c = UUID()
        let p = try store.createPlaylist(named: "P")
        try store.addToPlaylist(id: p.id, assetIds: [a, b])
        let q = try store.createPlaylist(named: "Q")
        try store.addToPlaylist(id: q.id, assetIds: [a])
        let backup = try LibraryBackupService().exportBackup(of: libraryURL)

        try store.removeFromPlaylist(id: p.id, assetIds: [b])
        try store.addToPlaylist(id: p.id, assetIds: [c])
        try store.deletePlaylist(id: q.id)

        _ = try LibraryBackupService().applyRestoreOverExisting(
            archiveURL: backup.archiveURL, destinationLibraryURL: libraryURL)

        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        let after = try LibraryStore(at: libraryURL)
        let pItems = try after.fetchPlaylistItems(playlistId: p.id).map(\.assetId)
        XCTAssertEqual(pItems, [a, c, b].map(\.uuidString),
                       "destination order kept; archive-only member appended at the end")
        XCTAssertEqual(try after.fetchPlaylistItems(playlistId: q.id).map(\.assetId), [a.uuidString],
                       "the deleted playlist is restored whole from the archive")
        XCTAssertEqual(Set(try after.fetchAllPlaylists().map(\.name)), ["P", "Q"])
    }
}
