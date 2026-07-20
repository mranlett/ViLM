import XCTest
@testable import LibraryCore

/// Guards the regeneration contract (DEFECT_INVENTORY C1): with
/// `overwrite: true` the generators must *attempt* generation even when the
/// output file already exists — proven here by pointing them at an unreadable
/// "video" so a real attempt throws, while the overwrite-false path still
/// silently skips. `regenerateAllVisuals` relies on this to rebuild visuals
/// after a trim/flip replaces the video file in place.
final class ContactSheetServiceTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!
    private var service: ContactSheetService!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactSheetServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
        service = ContactSheetService(store: store)
    }

    override func tearDownWithError() throws {
        service = nil
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    /// An asset whose "video" is a few junk bytes (undecodable) and whose
    /// cached visual already exists on disk.
    private func makeAssetWithExistingVisuals() throws -> Asset {
        let asset = Asset(relativePath: "clip.mp4", fileName: "clip.mp4")
        try Data([0, 1, 2, 3]).write(to: libraryURL.appendingPathComponent("clip.mp4"))
        for subdir in ["thumbnails", "contactSheets", "markers"] {
            try FileManager.default.createDirectory(
                at: libraryURL.appendingPathComponent(".catalog/\(subdir)"),
                withIntermediateDirectories: true)
        }
        try Data([9]).write(to: libraryURL.appendingPathComponent(".catalog/thumbnails/\(asset.id.uuidString).jpg"))
        try Data([9]).write(to: libraryURL.appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg"))
        return asset
    }

    func testThumbnailOverwriteFalseSkipsExistingFile() async throws {
        let asset = try makeAssetWithExistingVisuals()
        // Existing file + overwrite false → early return, no error even though
        // the video itself is unreadable.
        try await service.generateSingleThumbnail(for: asset, libraryURL: libraryURL, overwrite: false)
    }

    func testThumbnailOverwriteTrueAttemptsRegeneration() async throws {
        let asset = try makeAssetWithExistingVisuals()
        // overwrite: true must NOT early-return — it must attempt generation,
        // which throws here because the "video" is undecodable.
        do {
            try await service.generateSingleThumbnail(for: asset, libraryURL: libraryURL, overwrite: true)
            XCTFail("overwrite: true must attempt generation (and fail on an unreadable video), not silently skip")
        } catch { /* expected */ }
    }

    func testContactSheetOverwriteTrueAttemptsRegeneration() async throws {
        let asset = try makeAssetWithExistingVisuals()
        // Same contract for the contact sheet (which previously had no
        // overwrite parameter at all).
        try await service.generateContactSheet(for: asset, libraryURL: libraryURL, overwrite: false)
        do {
            try await service.generateContactSheet(for: asset, libraryURL: libraryURL, overwrite: true)
            XCTFail("overwrite: true must attempt generation, not silently skip")
        } catch { /* expected */ }
    }

    func testMarkerThumbnailOverwriteTrueAttemptsRegeneration() async throws {
        let asset = try makeAssetWithExistingVisuals()
        let markerId = UUID()
        try Data([9]).write(to: service.markerThumbnailURL(markerId: markerId, libraryURL: libraryURL))

        try await service.generateMarkerThumbnail(
            for: asset, markerId: markerId, timestampSeconds: 5, libraryURL: libraryURL, overwrite: false)
        do {
            try await service.generateMarkerThumbnail(
                for: asset, markerId: markerId, timestampSeconds: 5, libraryURL: libraryURL, overwrite: true)
            XCTFail("overwrite: true must attempt generation, not silently skip")
        } catch { /* expected */ }
    }
}
