import XCTest
@testable import LibraryCore

final class ActorLibraryPackageTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!
    private var profilesDir: URL!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActorLibraryPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
        profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func writeFile(_ name: String, bytes: [UInt8]) throws {
        try Data(bytes).write(to: profilesDir.appendingPathComponent(name))
    }

    // MARK: - Export

    func testExportOnlyIncludesActorProfiles() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe"))
        try store.saveEntityProfile(EntityProfile(id: "tag:Action"))

        let export = try store.exportActorLibrary()
        XCTAssertEqual(export.profiles.map(\.id), ["actor:Jane Doe"])
    }

    func testExportIncludesPrimaryAndGalleryFiles() throws {
        try writeFile("actor_Jane Doe.jpg", bytes: [1, 2, 3])
        let galleryToken = "https://example.com/1.jpg"
        try writeFile(ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: galleryToken), bytes: [4, 5, 6])

        try store.saveEntityProfile(EntityProfile(
            id: "actor:Jane Doe", photoUrl: nil, galleryUrls: [galleryToken]
        ))

        let export = try store.exportActorLibrary()
        XCTAssertEqual(export.photos.count, 2)
        XCTAssertTrue(export.photos.contains { $0.isPrimary && $0.data == Data([1, 2, 3]) })
        XCTAssertTrue(export.photos.contains { !$0.isPrimary && $0.sourceToken == galleryToken && $0.data == Data([4, 5, 6]) })
    }

    func testExportSkipsMissingFiles() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", galleryUrls: ["https://example.com/missing.jpg"]))
        let export = try store.exportActorLibrary()
        XCTAssertTrue(export.photos.isEmpty)
    }

    // MARK: - Plan

    func testPlanIdentifiesNewActor() throws {
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:New Person")
        ], photos: [])

        let plan = try store.planActorMerge(export)
        XCTAssertEqual(plan.newActorCount, 1)
        XCTAssertEqual(plan.updatedActorCount, 0)
    }

    func testPlanIdentifiesUpdatedActor() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", bio: "old bio"))
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe", bio: "new bio")
        ], photos: [])

        let plan = try store.planActorMerge(export)
        XCTAssertEqual(plan.newActorCount, 0)
        XCTAssertEqual(plan.updatedActorCount, 1)
    }

    func testPlanCountsNewVsDuplicatePhotos() throws {
        try writeFile("actor_Jane Doe.jpg", bytes: [9, 9, 9])
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe"))

        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe")
        ], photos: [
            ExportedPhoto(actorId: "actor:Jane Doe", isPrimary: true, sourceToken: nil,
                          contentHash: ProfileImageNaming.sha256Hex(Data([9, 9, 9])), fileExtension: "jpg", data: Data([9, 9, 9])),
            ExportedPhoto(actorId: "actor:Jane Doe", isPrimary: false, sourceToken: "https://example.com/new.jpg",
                          contentHash: ProfileImageNaming.sha256Hex(Data([1, 1, 1])), fileExtension: "jpg", data: Data([1, 1, 1]))
        ])

        let plan = try store.planActorMerge(export)
        XCTAssertEqual(plan.totalDuplicatePhotos, 1)
        XCTAssertEqual(plan.totalNewPhotos, 1)
    }

    // MARK: - Apply

    func testApplyInsertsNewActorWithPhotos() throws {
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:New Person", bio: "A bio")
        ], photos: [
            ExportedPhoto(actorId: "actor:New Person", isPrimary: true, sourceToken: nil,
                          contentHash: ProfileImageNaming.sha256Hex(Data([1, 2, 3])), fileExtension: "jpg", data: Data([1, 2, 3]))
        ])

        let result = try store.applyActorMerge(export)
        XCTAssertEqual(result.newActorCount, 1)
        XCTAssertEqual(result.newPhotoCount, 1)

        let saved = try XCTUnwrap(store.fetchEntityProfile(for: "actor:New Person"))
        XCTAssertEqual(saved.bio, "A bio")
        let fileURL = profilesDir.appendingPathComponent("actor_New Person.jpg")
        XCTAssertEqual(try Data(contentsOf: fileURL), Data([1, 2, 3]))
    }

    func testApplyMergesFieldLevelSourceWinsButNeverNullOverwrites() throws {
        // Destination has rich, fully-filled bio data.
        try store.saveEntityProfile(EntityProfile(
            id: "actor:Jane Doe",
            bio: "dest bio",
            homePage: "https://dest.example",
            gender: "Female",
            hairColor: "Brown",
            birthYear: 1990,
            countryOfOrigin: "Canada",
            tags: ["tag:Old"],
            akas: ["Janet"]
        ))

        // Source (import) is sparser: some real values (which should win),
        // some nil/empty (which must NOT wipe the destination's values).
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(
                id: "actor:Jane Doe",
                bio: "source bio",           // conflict → source wins
                homePage: nil,               // nil → keep destination's
                gender: nil,                 // nil → keep "Female"
                hairColor: "  ",             // whitespace-only → keep "Brown"
                birthYear: nil,              // nil → keep 1990
                countryOfOrigin: "USA",      // conflict → source wins
                tags: ["tag:New"],           // unioned
                akas: ["JD"]                 // unioned
            )
        ], photos: [])

        try store.applyActorMerge(export)

        let saved = try XCTUnwrap(store.fetchEntityProfile(for: "actor:Jane Doe"))
        XCTAssertEqual(saved.bio, "source bio", "a real source value wins a conflict")
        XCTAssertEqual(saved.homePage, "https://dest.example", "nil source must not wipe the destination")
        XCTAssertEqual(saved.gender, "Female", "nil source must not wipe the destination")
        XCTAssertEqual(saved.hairColor, "Brown", "empty source must not wipe the destination")
        XCTAssertEqual(saved.birthYear, 1990, "nil source must not wipe the destination")
        XCTAssertEqual(saved.countryOfOrigin, "USA", "a real source value wins a conflict")
        XCTAssertEqual(Set(saved.tags), Set(["tag:Old", "tag:New"]), "tags are unioned, not replaced")
        XCTAssertEqual(Set(saved.akas), Set(["Janet", "JD"]), "AKAs are unioned, not replaced")
    }

    func testApplyNeverRemovesExistingPhotosOnMatch() throws {
        let existingToken = "https://example.com/existing.jpg"
        try writeFile(ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: existingToken), bytes: [7, 7, 7])
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", galleryUrls: [existingToken]))

        let newToken = "https://example.com/new.jpg"
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe", galleryUrls: [newToken])
        ], photos: [
            ExportedPhoto(actorId: "actor:Jane Doe", isPrimary: false, sourceToken: newToken,
                          contentHash: ProfileImageNaming.sha256Hex(Data([8, 8, 8])), fileExtension: "jpg", data: Data([8, 8, 8]))
        ])

        try store.applyActorMerge(export)

        let saved = try XCTUnwrap(store.fetchEntityProfile(for: "actor:Jane Doe"))
        XCTAssertTrue(saved.galleryUrls.contains(existingToken), "existing photo reference must survive the merge")
        XCTAssertTrue(saved.galleryUrls.contains(newToken))
        // The old file on disk must still be there untouched.
        let existingFile = profilesDir.appendingPathComponent(ProfileImageNaming.galleryFileName(for: "actor:Jane Doe", token: existingToken))
        XCTAssertEqual(try Data(contentsOf: existingFile), Data([7, 7, 7]))
    }

    func testApplySkipsDuplicatePhotoByContentHash() throws {
        let bytes: [UInt8] = [5, 5, 5]
        try writeFile("actor_Jane Doe.jpg", bytes: bytes)
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe"))

        // Import brings "the same" photo (identical bytes) under a different token.
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe")
        ], photos: [
            ExportedPhoto(actorId: "actor:Jane Doe", isPrimary: true, sourceToken: nil,
                          contentHash: ProfileImageNaming.sha256Hex(Data(bytes)), fileExtension: "jpg", data: Data(bytes))
        ])

        let result = try store.applyActorMerge(export)
        XCTAssertEqual(result.newPhotoCount, 0)
        XCTAssertEqual(result.duplicatePhotoCount, 1)
    }

    func testApplyDoesNotReplaceExistingPrimary() throws {
        try writeFile("actor_Jane Doe.jpg", bytes: [1, 1, 1])
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", photoUrl: "https://example.com/current-primary.jpg"))

        // A different primary photo comes in from the import.
        let importedToken = "https://example.com/other-primary.jpg"
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe", photoUrl: importedToken)
        ], photos: [
            ExportedPhoto(actorId: "actor:Jane Doe", isPrimary: true, sourceToken: importedToken,
                          contentHash: ProfileImageNaming.sha256Hex(Data([2, 2, 2])), fileExtension: "jpg", data: Data([2, 2, 2]))
        ])

        try store.applyActorMerge(export)

        let saved = try XCTUnwrap(store.fetchEntityProfile(for: "actor:Jane Doe"))
        XCTAssertEqual(saved.photoUrl, "https://example.com/current-primary.jpg", "existing primary selection must not be silently swapped")
        XCTAssertTrue(saved.galleryUrls.contains(importedToken), "the imported primary should still be added to the gallery")
    }

    func testRatingPersistsAndMergesNonDestructively() throws {
        // Round-trip through the v15 column.
        try store.saveEntityProfile(EntityProfile(id: "actor:Jane Doe", rating: 4))
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Jane Doe")?.rating, 4)

        // Merge: a nil imported rating keeps the destination's…
        let keepExport = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe", rating: nil)
        ], photos: [])
        try store.applyActorMerge(keepExport)
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Jane Doe")?.rating, 4,
                       "nil source rating must not wipe the destination's")

        // …and a real imported rating wins the conflict.
        let winExport = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe", rating: 5)
        ], photos: [])
        try store.applyActorMerge(winExport)
        XCTAssertEqual(try store.fetchEntityProfile(for: "actor:Jane Doe")?.rating, 5)
    }

    func testApplyLeavesUnmatchedActorsUntouched() throws {
        try store.saveEntityProfile(EntityProfile(id: "actor:Only In Destination", bio: "untouched"))

        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Someone Else")
        ], photos: [])

        try store.applyActorMerge(export)

        let saved = try XCTUnwrap(store.fetchEntityProfile(for: "actor:Only In Destination"))
        XCTAssertEqual(saved.bio, "untouched")
    }

    func testApplyIsIdempotent() throws {
        let export = ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: [
            EntityProfile(id: "actor:Jane Doe", bio: "bio")
        ], photos: [
            ExportedPhoto(actorId: "actor:Jane Doe", isPrimary: true, sourceToken: nil,
                          contentHash: ProfileImageNaming.sha256Hex(Data([1, 2, 3])), fileExtension: "jpg", data: Data([1, 2, 3]))
        ])

        try store.applyActorMerge(export)
        let result = try store.applyActorMerge(export)

        XCTAssertEqual(result.newPhotoCount, 0, "re-applying the same export must not duplicate photos")
        XCTAssertEqual(result.duplicatePhotoCount, 1)
        let saved = try XCTUnwrap(store.fetchEntityProfile(for: "actor:Jane Doe"))
        XCTAssertEqual(saved.galleryUrls.count, 1)
    }
}
