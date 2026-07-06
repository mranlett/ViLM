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

    func testDeleteAsset() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        let asset = try XCTUnwrap(store.fetchAllAssets().first)

        try store.deleteAsset(asset)
        XCTAssertTrue(try store.fetchAllAssets().isEmpty)
    }

    func testDataPersistsAcrossReopen() throws {
        try store.saveAsset(Asset(relativePath: "a.mp4", fileName: "a.mp4"))
        store = nil

        let reopened = try LibraryStore(at: libraryURL)
        XCTAssertEqual(try reopened.fetchAllAssets().count, 1)
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
