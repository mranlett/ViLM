import XCTest
@testable import LibraryCore

final class LibraryStoreTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        // LibraryStore caches open connections in process-wide static state.
        // Drop them after every test so the cache can't leak connections (or
        // surprises) from one test into the next as the suite grows.
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    // MARK: - Assets

    func testSaveAndFetchAsset() throws {
        let asset = Asset(relativePath: "clips/a.mp4", fileName: "a.mp4")
        try store.saveAsset(asset)

        let fetched = try store.fetchAllAssets()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].relativePath, "clips/a.mp4")
        XCTAssertEqual(fetched[0].fileName, "a.mp4")
        XCTAssertEqual(fetched[0].status, .unreviewed)
    }

    func testSaveAssetIsInsertOnly() throws {
        // saveAsset uses INSERT OR IGNORE: saving an asset whose relative
        // path already exists must not create a duplicate or modify the row.
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4")
        try store.saveAsset(asset)

        var modified = asset
        modified.status = .reviewed
        try store.saveAsset(modified)

        let fetched = try store.fetchAllAssets()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].status, .unreviewed, "saveAsset must not update existing rows; use updateAsset")
    }

    func testUpdateAssetPersistsMetadata() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        var asset = try XCTUnwrap(store.fetchAllAssets().first)

        asset.status = .reviewed
        asset.tags = ["actor:Jane Doe", "tag:Running", "studio:Acme"]
        asset.rating = 4
        asset.notes = "great"
        try store.updateAsset(asset)

        let fetched = try XCTUnwrap(store.fetchAllAssets().first)
        XCTAssertEqual(fetched.status, .reviewed)
        XCTAssertEqual(Set(fetched.tags), Set(["actor:Jane Doe", "tag:Running", "studio:Acme"]))
        XCTAssertEqual(fetched.rating, 4)
        XCTAssertEqual(fetched.notes, "great")
        XCTAssertEqual(fetched.actors, ["Jane Doe"])
        XCTAssertEqual(fetched.actions, ["Running"])
        XCTAssertEqual(fetched.studios, ["Acme"])
    }

    func testPlayCountDefaultsToZeroAndPersists() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        var asset = try XCTUnwrap(store.fetchAllAssets().first)
        XCTAssertEqual(asset.playCount, 0)
        XCTAssertNil(asset.lastPlayedAt)

        let playedAt = Date()
        asset.playCount += 1
        asset.lastPlayedAt = playedAt
        try store.updateAsset(asset)

        let fetched = try XCTUnwrap(store.fetchAllAssets().first)
        XCTAssertEqual(fetched.playCount, 1)
        // Round-trip the actual timestamp, not just "non-nil": a wrong-precision
        // or timezone-shifted serialization would pass a non-nil check but fail
        // this. Tolerance covers the column's millisecond storage precision.
        let roundTripped = try XCTUnwrap(fetched.lastPlayedAt)
        XCTAssertEqual(roundTripped.timeIntervalSince1970, playedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testDeleteAsset() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let asset = try XCTUnwrap(store.fetchAllAssets().first)

        try store.deleteAsset(asset)
        XCTAssertTrue(try store.fetchAllAssets().isEmpty)
    }

    func testDataPersistsAcrossReopen() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        store = nil

        // LibraryStore keeps a process-wide cache of open DatabaseQueues keyed
        // by path, so simply re-opening the same URL would hand back the very
        // same in-memory connection — proving nothing about disk durability.
        // Drop the cache first so the reopen genuinely opens a fresh connection
        // and re-reads the bytes SQLite wrote to disk.
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)

        let reopened = try LibraryStore(at: libraryURL)
        XCTAssertEqual(try reopened.fetchAllAssets().count, 1)
        XCTAssertEqual(try reopened.fetchAllAssets().first?.relativePath, "a.mp4")
    }

    func testEvictCachedConnectionsIsNonDestructiveAndReopenable() throws {
        // Two distinct libraries, each with its own persisted asset.
        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        let otherStore = try LibraryStore(at: otherURL)
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        try otherStore.saveAsset(Asset(relativePath: "b.mp4", fileName: "b.mp4"))

        // Evict everything except the active library. This drops the other
        // library's cached connection; the kept one stays cached.
        LibraryStore.evictCachedConnections(keepingLibraryAt: libraryURL)

        // The guarantee that matters: eviction must never lose data. Both the
        // kept connection (reused from cache) and the evicted one (re-opened
        // fresh from disk) still return their persisted rows intact.
        XCTAssertEqual(try LibraryStore(at: libraryURL).fetchAllAssets().map(\.relativePath), ["a.mp4"])
        XCTAssertEqual(try LibraryStore(at: otherURL).fetchAllAssets().map(\.relativePath), ["b.mp4"])

        // Evicting all connections is likewise safe and reopenable.
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        XCTAssertEqual(try LibraryStore(at: libraryURL).fetchAllAssets().count, 1)
        XCTAssertEqual(try LibraryStore(at: otherURL).fetchAllAssets().count, 1)

        try? FileManager.default.removeItem(at: otherURL)
    }

    func testTargetedEvictionOnlyDropsThatLibrary() throws {
        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let otherStore = try LibraryStore(at: otherURL)
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        try otherStore.saveAsset(Asset(relativePath: "b.mp4", fileName: "b.mp4"))

        // Targeted eviction is non-destructive and scoped: the evicted
        // library reopens fresh from disk; the other keeps working.
        LibraryStore.evictCachedConnection(forLibraryAt: otherURL)
        XCTAssertEqual(try LibraryStore(at: otherURL).fetchAllAssets().map(\.relativePath), ["b.mp4"])
        XCTAssertEqual(try LibraryStore(at: libraryURL).fetchAllAssets().map(\.relativePath), ["a.mp4"])
    }

    func testSnapshotDatabaseIsConsistentAndIndependent() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", bio: "kept"))

        // Snapshot into a second library-shaped folder, then open it as a
        // normal library: content matches the source at snapshot time.
        let snapLib = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-snap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapLib) }
        let snapCatalog = snapLib.appendingPathComponent(".catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: snapCatalog, withIntermediateDirectories: true)
        try store.snapshotDatabase(to: snapCatalog.appendingPathComponent("catalog.sqlite"))

        // A write to the source AFTER the snapshot must not appear in it.
        try store.saveAsset(Asset(relativePath: "later.mp4", fileName: "later.mp4"))

        let snapStore = try LibraryStore(at: snapLib)
        defer { LibraryStore.evictCachedConnection(forLibraryAt: snapLib) }
        XCTAssertEqual(try snapStore.fetchAllAssets().map(\.relativePath), ["a.mp4"])
        XCTAssertEqual(try snapStore.fetchEntityProfile(for: "actor:Jane Doe")?.bio, "kept")
        try snapStore.runIntegrityCheck()
    }

    // MARK: - Entity Profiles

    func testEntityProfileRoundTrip() throws {
        let profile = EntityProfile(
            id: "actor:Jane Doe",
            bio: "A bio",
            photoUrl: "https://example.com/jane.jpg",
            gender: "Female",
            birthYear: 1990,
            countryOfOrigin: "US",
            tags: ["tag:Lead"],
            galleryUrls: ["https://example.com/1.jpg"],
            akas: ["JD", "Janie"]
        )
        try store.saveEntityProfile(profile)

        let fetched = try XCTUnwrap(store.fetchEntityProfile(for: "actor:Jane Doe"))
        XCTAssertEqual(fetched.bio, "A bio")
        XCTAssertEqual(fetched.photoUrl, "https://example.com/jane.jpg")
        XCTAssertEqual(fetched.gender, "Female")
        XCTAssertEqual(fetched.birthYear, 1990)
        XCTAssertEqual(fetched.tags, ["tag:Lead"])
        XCTAssertEqual(fetched.galleryUrls, ["https://example.com/1.jpg"])
        XCTAssertEqual(fetched.akas, ["JD", "Janie"])
    }

    func testDeleteEntityProfile() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe"))
        try store.deleteEntityProfile(for: "actor:Jane Doe")
        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Jane Doe"))
    }

    func testResolveActorAKA() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", akas: ["JD"]))

        XCTAssertEqual(try store.resolveActorAKA(for: "JD"), "Jane Doe")
        XCTAssertEqual(try store.resolveActorAKA(for: "Unknown Person"), "Unknown Person")
    }

    // MARK: - Global Rename

    func testRenameTagGloballyUpdatesAssetsAndProfile() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        var asset = try XCTUnwrap(store.fetchAllAssets().first)
        asset.tags = ["actor:Old Name", "tag:Keep"]
        try store.updateAsset(asset)

        try store.saveEntityProfile(EntityProfile(id: "actor:Old Name", bio: "kept bio"))

        try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        let fetched = try XCTUnwrap(store.fetchAllAssets().first)
        XCTAssertEqual(Set(fetched.tags), Set(["actor:New Name", "tag:Keep"]))

        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Old Name"))
        let renamedProfile = try XCTUnwrap(store.fetchEntityProfile(for: "actor:New Name"))
        XCTAssertEqual(renamedProfile.bio, "kept bio")
    }

    func testRenameTagGloballyDeduplicates() throws {
        // Renaming onto a tag the asset already has must not leave duplicates.
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        var asset = try XCTUnwrap(store.fetchAllAssets().first)
        asset.tags = ["actor:Old Name", "actor:New Name"]
        try store.updateAsset(asset)

        try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        let fetched = try XCTUnwrap(store.fetchAllAssets().first)
        XCTAssertEqual(fetched.tags, ["actor:New Name"])
    }

    func testRenameTagGloballyPreservesExistingDestinationProfile() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Old Name", bio: "old bio"))
        try store.saveEntityProfile(EntityProfile(id: "actor:New Name", bio: "existing bio"))

        try store.renameTagGlobally(oldTag: "actor:Old Name", newTag: "actor:New Name")

        XCTAssertNil(try store.fetchEntityProfile(for: "actor:Old Name"))
        let destination = try XCTUnwrap(store.fetchEntityProfile(for: "actor:New Name"))
        XCTAssertEqual(destination.bio, "existing bio", "an existing destination profile must not be overwritten")
    }

    // MARK: - Series Rename

    func testRenameSeriesMergesVariants() throws {
        var a = Asset(relativePath: "a.mp4", fileName: "a.mp4"); a.videoName = "the office"
        var b = Asset(relativePath: "b.mp4", fileName: "b.mp4"); b.videoName = "The Office "
        var c = Asset(relativePath: "c.mp4", fileName: "c.mp4"); c.videoName = "Unrelated"
        try store.saveAsset(a); try store.saveAsset(b); try store.saveAsset(c)
        // saveAsset is insert-only and doesn't persist videoName, so set it via update.
        for var asset in try store.fetchAllAssets() {
            switch asset.relativePath {
            case "a.mp4": asset.videoName = "the office"
            case "b.mp4": asset.videoName = "The Office "
            case "c.mp4": asset.videoName = "Unrelated"
            default: break
            }
            try store.updateAsset(asset)
        }

        try store.renameSeries(from: ["the office", "The Office "], to: "The Office")

        let byPath = Dictionary(uniqueKeysWithValues: try store.fetchAllAssets().map { ($0.relativePath, $0) })
        XCTAssertEqual(byPath["a.mp4"]?.videoName, "The Office")
        XCTAssertEqual(byPath["b.mp4"]?.videoName, "The Office")
        XCTAssertEqual(byPath["c.mp4"]?.videoName, "Unrelated", "unrelated series must be untouched")
    }

    // MARK: - Smart Collections

    func testSmartCollectionRoundTripAndOrdering() throws {
        let older = SmartCollection(name: "Older", filterData: Data("a".utf8), createdAt: Date(timeIntervalSince1970: 100))
        let newer = SmartCollection(name: "Newer", filterData: Data("b".utf8), createdAt: Date(timeIntervalSince1970: 200))
        try store.saveSmartCollection(newer)
        try store.saveSmartCollection(older)

        let fetched = try store.fetchAllSmartCollections()
        XCTAssertEqual(fetched.map(\.name), ["Older", "Newer"], "collections are ordered by creation date ascending")
        XCTAssertEqual(fetched[0].filterData, Data("a".utf8))
    }

    func testDeleteSmartCollection() throws {
        let collection = SmartCollection(name: "Temp", filterData: Data())
        try store.saveSmartCollection(collection)
        try store.deleteSmartCollection(id: collection.id)
        XCTAssertTrue(try store.fetchAllSmartCollections().isEmpty)
    }
}
