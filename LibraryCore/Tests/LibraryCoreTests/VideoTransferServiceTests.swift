import XCTest
@testable import LibraryCore

/// Covers the deterministic, filesystem-light parts of the transfer tool:
/// the pure cross-library duplicate-candidate matching, streaming content
/// hashing, the collision-avoiding destination path, and a full-column
/// insertAsset round-trip. The end-to-end move (real multi-GB copies across
/// two mounted volumes) is verified manually.
final class VideoTransferServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // These tests open LibraryStores at temp paths; drop the process-wide
        // connection cache so nothing leaks into the next test.
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Duplicate candidate matching

    func testMatchesOnSizeAndDuration() {
        let a = UUID(), b = UUID()
        let sideA = [VideoFingerprint(assetId: a, sizeBytes: 1000, durationSeconds: 60)]
        let sideB = [VideoFingerprint(assetId: b, sizeBytes: 1000, durationSeconds: 60)]
        let pairs = VideoTransferService.duplicateCandidates(sideA: sideA, sideB: sideB)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.sideAAssetId, a)
        XCTAssertEqual(pairs.first?.sideBAssetId, b)
    }

    func testDifferentSizeIsNotACandidate() {
        let sideA = [VideoFingerprint(assetId: UUID(), sizeBytes: 1000, durationSeconds: 60)]
        let sideB = [VideoFingerprint(assetId: UUID(), sizeBytes: 2000, durationSeconds: 60)]
        XCTAssertTrue(VideoTransferService.duplicateCandidates(sideA: sideA, sideB: sideB).isEmpty)
    }

    func testSameSizeDifferentDurationIsNotACandidate() {
        let sideA = [VideoFingerprint(assetId: UUID(), sizeBytes: 1000, durationSeconds: 60)]
        let sideB = [VideoFingerprint(assetId: UUID(), sizeBytes: 1000, durationSeconds: 61)]
        XCTAssertTrue(VideoTransferService.duplicateCandidates(sideA: sideA, sideB: sideB).isEmpty)
    }

    func testUnknownDurationStillCandidateBySize() {
        // A nil duration on either side keeps it a candidate (hashing is the
        // real gate) — so a video whose duration couldn't be read isn't
        // silently excluded from the duplicate check.
        let sideA = [VideoFingerprint(assetId: UUID(), sizeBytes: 1000, durationSeconds: nil)]
        let sideB = [VideoFingerprint(assetId: UUID(), sizeBytes: 1000, durationSeconds: 60)]
        XCTAssertEqual(VideoTransferService.duplicateCandidates(sideA: sideA, sideB: sideB).count, 1)
    }

    func testZeroSizeIsIgnored() {
        let sideA = [VideoFingerprint(assetId: UUID(), sizeBytes: 0, durationSeconds: nil)]
        let sideB = [VideoFingerprint(assetId: UUID(), sizeBytes: 0, durationSeconds: nil)]
        XCTAssertTrue(VideoTransferService.duplicateCandidates(sideA: sideA, sideB: sideB).isEmpty)
    }

    // MARK: - Content hashing

    func testContentHashMatchesForIdenticalBytesAndDiffersOtherwise() throws {
        let a = tempDir.appendingPathComponent("a.bin")
        let b = tempDir.appendingPathComponent("b.bin")
        let c = tempDir.appendingPathComponent("c.bin")
        let payload = Data((0..<200_000).map { UInt8($0 % 256) }) // spans multiple chunks
        try payload.write(to: a)
        try payload.write(to: b)
        try (payload + Data([9])).write(to: c)

        let service = VideoTransferService()
        let ha = try service.contentHash(of: a)
        let hb = try service.contentHash(of: b)
        let hc = try service.contentHash(of: c)
        XCTAssertEqual(ha, hb, "identical bytes must hash identically")
        XCTAssertNotEqual(ha, hc, "different bytes must hash differently")
        // Cached second read returns the same value.
        XCTAssertEqual(try service.contentHash(of: a), ha)
    }

    // MARK: - Destination path collision avoidance

    func testAvailableRelativePathAvoidsCollision() throws {
        let existing = tempDir.appendingPathComponent("Movie.mp4")
        try Data([1, 2, 3]).write(to: existing)
        let path = VideoTransferService.availableRelativePath(preferred: "Movie.mp4", in: tempDir)
        XCTAssertEqual(path, "Movie-1.mp4")

        // Free path is returned unchanged.
        XCTAssertEqual(
            VideoTransferService.availableRelativePath(preferred: "Other.mp4", in: tempDir),
            "Other.mp4"
        )
    }

    // MARK: - End-to-end move (dummy file, no real video)

    func testMoveCopiesVerifiesAndRemovesSource() async throws {
        let sourceLib = tempDir.appendingPathComponent("source", isDirectory: true)
        let destLib = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destLib, withIntermediateDirectories: true)

        // A stand-in "video" file (thumbnail generation will fail on it, which
        // the move tolerates via try?; the file copy/verify/metadata path is
        // what this exercises).
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: sourceLib.appendingPathComponent("clip.mp4"))

        let sourceStore = try LibraryStore(at: sourceLib)
        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4",
                          tags: ["actor:Jane Doe"], rating: 5, videoName: "My Clip")
        try sourceStore.insertAsset(asset)

        let service = VideoTransferService()
        let outcome = try await service.moveVideo(asset, from: sourceLib, to: destLib)

        // Destination has the file, byte-identical, plus a full metadata row.
        let destFile = destLib.appendingPathComponent(outcome.destinationRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        XCTAssertEqual(try Data(contentsOf: destFile), payload)

        let destStore = try LibraryStore(at: destLib)
        let destAssets = try destStore.fetchAllAssets()
        XCTAssertEqual(destAssets.count, 1)
        XCTAssertEqual(destAssets.first?.rating, 5)
        XCTAssertEqual(destAssets.first?.videoName, "My Clip")
        XCTAssertEqual(destAssets.first?.tags, ["actor:Jane Doe"])

        // Source is gone: the file no longer sits at its path and the row is
        // removed. (Verification passed, so the source was safe to delete.)
        XCTAssertTrue(outcome.sourceRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceLib.appendingPathComponent("clip.mp4").path))
        XCTAssertTrue(try sourceStore.fetchAllAssets().isEmpty)
    }

    // MARK: - Verification failure preserves the source (data-loss guard)

    func testFailedVerificationKeepsSourceAndRollsBackDestination() async throws {
        let sourceLib = tempDir.appendingPathComponent("vsrc", isDirectory: true)
        let destLib = tempDir.appendingPathComponent("vdst", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destLib, withIntermediateDirectories: true)

        let payload = Data((0..<120_000).map { UInt8($0 % 251) })
        let sourceFile = sourceLib.appendingPathComponent("clip.mp4")
        try payload.write(to: sourceFile)

        let sourceStore = try LibraryStore(at: sourceLib)
        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4", rating: 5)
        try sourceStore.insertAsset(asset)

        // Force the copy-verify step to report a hash that can't match the
        // source, standing in for a corrupted/incomplete copy. The move must
        // abort *before* deleting the source — this is the one guarantee whose
        // failure would mean permanent data loss.
        let service = VideoTransferService()
        service.copyVerificationHash = { _ in String(repeating: "0", count: 64) }

        do {
            _ = try await service.moveVideo(asset, from: sourceLib, to: destLib)
            XCTFail("move must throw when copy verification fails")
        } catch VideoTransferError.copyVerificationFailed {
            // expected
        }

        // Source survives fully intact: file present and byte-identical, row kept.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path),
                      "the source file must never be deleted when verification fails")
        XCTAssertEqual(try Data(contentsOf: sourceFile), payload)
        let survivingSource = try XCTUnwrap(sourceStore.fetchAllAssets().first)
        XCTAssertEqual(survivingSource.rating, 5, "the source DB row must be left untouched")

        // Destination is rolled back: no promoted file, no leftover temp file,
        // and no orphan metadata row (insert happens only after verify passes).
        let destFile = destLib.appendingPathComponent("clip.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFile.appendingPathExtension("vilmtmp").path),
                       "the temp copy must be cleaned up on rollback")
        let destStore = try LibraryStore(at: destLib)
        XCTAssertTrue(try destStore.fetchAllAssets().isEmpty, "a failed move must leave no orphan row in the destination")
    }

    // MARK: - The full package moves: cached visuals + fingerprint travel

    func testMoveCarriesVisualsAndFingerprintAndClearsSource() async throws {
        let sourceLib = tempDir.appendingPathComponent("pkgsrc", isDirectory: true)
        let destLib = tempDir.appendingPathComponent("pkgdst", isDirectory: true)
        for lib in [sourceLib, destLib] {
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        }
        let payload = Data((0..<60_000).map { UInt8($0 % 251) })
        try payload.write(to: sourceLib.appendingPathComponent("clip.mp4"))

        let sourceStore = try LibraryStore(at: sourceLib)
        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4")
        try sourceStore.insertAsset(asset)
        let marker = SceneMarker(assetId: asset.id, timestampSeconds: 12, label: "scene")
        try sourceStore.saveSceneMarker(marker)

        // Source has cached visuals (incl. a custom poster) + a marker preview.
        for subdir in ["thumbnails", "contactSheets", "markers"] {
            try FileManager.default.createDirectory(
                at: sourceLib.appendingPathComponent(".catalog/\(subdir)"), withIntermediateDirectories: true)
        }
        try Data([1, 1]).write(to: sourceLib.appendingPathComponent(".catalog/thumbnails/\(asset.id.uuidString).jpg"))
        try Data([2, 2]).write(to: sourceLib.appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg"))
        try Data([3, 3]).write(to: sourceLib.appendingPathComponent(".catalog/markers/\(marker.id.uuidString).jpg"))

        // And a duplicate-scan fingerprint keyed to the real file attrs.
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceLib.appendingPathComponent("clip.mp4").path)
        let srcSize = attrs[.size] as! Int64
        let srcMtime = (attrs[.modificationDate] as! Date).timeIntervalSince1970
        var srcPrints = FrameFingerprintStore(libraryURL: sourceLib)
        srcPrints.setHashes([11, 22, 33], relativePath: "clip.mp4", sizeBytes: srcSize, modified: srcMtime)
        srcPrints.save()

        let outcome = try await VideoTransferService().moveVideo(asset, from: sourceLib, to: destLib)

        // Destination: visuals arrived byte-identical under the NEW ids
        // (copied, not regenerated — a dummy payload can't be re-generated from).
        XCTAssertEqual(
            try Data(contentsOf: destLib.appendingPathComponent(".catalog/thumbnails/\(outcome.newAssetId.uuidString).jpg")),
            Data([1, 1]), "the poster is copied (preserving a custom thumbnail), not regenerated")
        XCTAssertEqual(
            try Data(contentsOf: destLib.appendingPathComponent(".catalog/contactSheets/\(outcome.newAssetId.uuidString).jpg")),
            Data([2, 2]))
        let destStore = try LibraryStore(at: destLib)
        let destMarker = try XCTUnwrap(destStore.fetchSceneMarkers(for: outcome.newAssetId).first)
        XCTAssertEqual(
            try Data(contentsOf: destLib.appendingPathComponent(".catalog/markers/\(destMarker.id.uuidString).jpg")),
            Data([3, 3]), "the marker preview travels under its new marker id")

        // Destination: fingerprint carried, re-keyed to the new path + file attrs.
        let destAttrs = try FileManager.default.attributesOfItem(
            atPath: destLib.appendingPathComponent(outcome.destinationRelativePath).path)
        let destPrints = FrameFingerprintStore(libraryURL: destLib)
        XCTAssertEqual(
            destPrints.validHashes(
                relativePath: outcome.destinationRelativePath,
                sizeBytes: destAttrs[.size] as! Int64,
                modified: (destAttrs[.modificationDate] as! Date).timeIntervalSince1970),
            [11, 22, 33], "the fingerprint travels with the video")

        // Source: file, row, visuals, and fingerprint entry are all gone.
        XCTAssertTrue(outcome.sourceRemoved)
        XCTAssertTrue(try sourceStore.fetchAllAssets().isEmpty)
        XCTAssertNil(FrameFingerprintStore(libraryURL: sourceLib).entries["clip.mp4"],
                     "the source's fingerprint entry leaves with the video")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sourceLib.appendingPathComponent(".catalog/markers/\(marker.id.uuidString).jpg").path))
    }

    // MARK: - Delete ordering: file removal failure must never cost metadata

    func testFailedFileRemovalPreservesRowAndMarkers() throws {
        let lib = tempDir.appendingPathComponent("dellib", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: lib.appendingPathComponent("clip.mp4"))

        let store = try LibraryStore(at: lib)
        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4", rating: 5)
        try store.insertAsset(asset)
        try store.saveSceneMarker(SceneMarker(assetId: asset.id, timestampSeconds: 10, label: "keep"))

        // Force the video-file removal to fail (unmounted volume / revoked
        // scope stand-in). The delete must abort with the catalog untouched.
        let service = VideoTransferService()
        service.fileRemover = { _, _ in throw CocoaError(.fileWriteNoPermission) }

        XCTAssertThrowsError(try service.deleteVideoAndArtifacts(asset, in: lib, toTrash: true))

        // Row, markers, and file all survive — nothing was half-deleted.
        let survivors = try store.fetchAllAssets()
        XCTAssertEqual(survivors.map(\.rating), [5], "the DB row must survive a failed file removal")
        XCTAssertEqual(try store.fetchSceneMarkers(for: asset.id).map(\.label), ["keep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.appendingPathComponent("clip.mp4").path))
    }

    func testSuccessfulDeleteRemovesRowMarkersAndArtifacts() throws {
        let lib = tempDir.appendingPathComponent("dellib2", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: lib.appendingPathComponent("clip.mp4"))

        let store = try LibraryStore(at: lib)
        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4")
        try store.insertAsset(asset)
        let marker = SceneMarker(assetId: asset.id, timestampSeconds: 10)
        try store.saveSceneMarker(marker)
        // A marker preview file that must be cleaned up with the delete.
        let markersDir = lib.appendingPathComponent(".catalog/markers")
        try FileManager.default.createDirectory(at: markersDir, withIntermediateDirectories: true)
        let markerThumb = markersDir.appendingPathComponent("\(marker.id.uuidString).jpg")
        try Data([9]).write(to: markerThumb)

        let service = VideoTransferService()
        try service.deleteVideoAndArtifacts(asset, in: lib, toTrash: false)

        XCTAssertTrue(try store.fetchAllAssets().isEmpty)
        XCTAssertTrue(try store.fetchSceneMarkers(for: asset.id).isEmpty, "marker rows cascade with the asset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.appendingPathComponent("clip.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerThumb.path), "marker preview file is removed too")
    }

    // MARK: - Actor profile + photo travels with the moved video

    /// 🚨 A moved video's studio is matched between libraries by NAME.
    ///
    /// The copy used to check the destination for `"studio:Name"` and, finding
    /// nothing, write the SOURCE's profile across verbatim — key included.
    /// Once each library mints its own uid that check always misses and the
    /// sender's uid becomes a key in the receiver: a duplicate studio, which
    /// is exactly what the federation rule exists to prevent.
    func testAMovedVideosStudioIsMatchedByNameNotByKey() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceLib = tempDir.appendingPathComponent("src", isDirectory: true)
        let destLib = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destLib, withIntermediateDirectories: true)
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try payload.write(to: sourceLib.appendingPathComponent("clip.mp4"))

        // The SAME studio, keyed differently in each library — the state the
        // re-key produces.
        let sourceStore = try LibraryStore(at: sourceLib)
        let destStore = try LibraryStore(at: destLib)
        try sourceStore.saveEntityProfile(EntityProfile(id: UUID().uuidString,
                                                        entityType: "studio",
                                                        displayName: "Silver River",
                                                        bio: "from source"))
        let destUid = UUID().uuidString
        try destStore.saveEntityProfile(EntityProfile(id: destUid, entityType: "studio",
                                                      displayName: "Silver River",
                                                      bio: "already here"))

        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4",
                          tags: ["studio:Silver River"])
        try sourceStore.insertAsset(asset)

        _ = try await VideoTransferService().moveVideo(asset, from: sourceLib, to: destLib)

        let studios = try destStore.fetchAllEntityProfiles().filter { $0.type == "studio" }
        XCTAssertEqual(studios.count, 1, "the destination already had this studio by name")
        XCTAssertEqual(studios.first?.id, destUid, "its own key must survive")
        XCTAssertEqual(studios.first?.bio, "already here",
                       "the richer local copy is not overwritten")
    }

    func testMoveCarriesActorProfileAndPhoto() async throws {
        let sourceLib = tempDir.appendingPathComponent("src2", isDirectory: true)
        let destLib = tempDir.appendingPathComponent("dst2", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destLib, withIntermediateDirectories: true)

        // A stand-in video referencing an actor.
        try Data((0..<50_000).map { UInt8($0 % 251) }).write(to: sourceLib.appendingPathComponent("clip.mp4"))

        let sourceStore = try LibraryStore(at: sourceLib)
        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4", tags: ["actor:Jane Doe"])
        try sourceStore.insertAsset(asset)

        // Source has a rich profile + a primary photo file for that actor.
        try sourceStore.saveEntityProfile(EntityProfile(
            id: "actor:Jane Doe", bio: "A bio", gender: "Female", hairColor: "Brown"
        ))
        let sourceProfilesDir = sourceLib.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: sourceProfilesDir, withIntermediateDirectories: true)
        let photoData = Data((0..<4_000).map { UInt8($0 % 200) })
        try photoData.write(to: sourceProfilesDir.appendingPathComponent(
            ProfileImageNaming.primaryFileName(for: "actor:Jane Doe")))

        let service = VideoTransferService()
        let outcome = try await service.moveVideo(asset, from: sourceLib, to: destLib)

        XCTAssertEqual(outcome.actorsTransferred, 1)
        XCTAssertEqual(outcome.actorPhotosTransferred, 1)

        // The destination now has the actor's profile...
        let destStore = try LibraryStore(at: destLib)
        let destProfile = try destStore.fetchEntityProfile(for: "actor:Jane Doe")
        XCTAssertEqual(destProfile?.bio, "A bio")
        XCTAssertEqual(destProfile?.gender, "Female")
        // ...and the photo file, byte-identical.
        let destPhoto = destLib.appendingPathComponent(".catalog/profiles")
            .appendingPathComponent(ProfileImageNaming.primaryFileName(for: "actor:Jane Doe"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destPhoto.path))
        XCTAssertEqual(try Data(contentsOf: destPhoto), photoData)
    }

    // MARK: - insertAsset round-trip (all columns)

    func testInsertAssetPersistsEveryColumn() throws {
        let store = try LibraryStore(at: tempDir)
        let asset = Asset(
            id: UUID(),
            relativePath: "Sub/Folder/My Movie.mp4",
            fileName: "My Movie.mp4",
            status: .reviewed,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            tags: ["actor:Jane Doe", "tag:Action", "studio:Acme"],
            externalLink: "https://example.com",
            notes: "some notes",
            rating: 4,
            videoName: "My Series",
            seasonNumber: 2,
            episodeNumber: 5,
            episode: "The Big One",
            playCount: 3,
            lastPlayedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        try store.insertAsset(asset)

        let fetched = try store.fetchAllAssets().first { $0.id == asset.id }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.relativePath, asset.relativePath)
        XCTAssertEqual(fetched?.fileName, asset.fileName)
        XCTAssertEqual(fetched?.status, .reviewed)
        XCTAssertEqual(fetched?.notes, "some notes")
        XCTAssertEqual(fetched?.rating, 4)
        XCTAssertEqual(fetched?.videoName, "My Series")
        XCTAssertEqual(fetched?.seasonNumber, 2)
        XCTAssertEqual(fetched?.episodeNumber, 5)
        XCTAssertEqual(fetched?.episode, "The Big One")
        XCTAssertEqual(fetched?.playCount, 3)
        XCTAssertEqual(fetched?.externalLink, "https://example.com")
        XCTAssertEqual(Set(fetched?.tags ?? []), Set(asset.tags))
    }
}
