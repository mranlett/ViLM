import XCTest
@testable import LibraryCore

/// Sync must reach a fixed point. An actor that is offered, approved, applied
/// and then offered again is worse than a failure: nothing reports an error, so
/// the only symptom is that the same names never go away.
final class ActorSyncConvergenceTests: XCTestCase {

    private var root: URL!
    private var libA: URL!
    private var libB: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-converge-\(UUID().uuidString)")
        libA = root.appendingPathComponent("A")
        libB = root.appendingPathComponent("B")
        for url in [libA!, libB!] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(".catalog/profiles"),
                withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePrimary(_ libraryURL: URL, actorId: String, bytes: UInt8) throws {
        let data = Data(repeating: bytes, count: 512)
        try data.write(to: libraryURL.appendingPathComponent(".catalog/profiles")
            .appendingPathComponent(ProfileImageNaming.primaryFileName(for: actorId)))
    }

    /// The regression that stranded 15 actors.
    ///
    /// One library's primary is the local sentinel and the other's is a remote
    /// URL. The sentinel used to be stored verbatim as a GALLERY token in the
    /// destination — a token the export filter deliberately skips — so the
    /// photo never appeared in that library's exports and the plan reported the
    /// same gap on every pass.
    func testPrimaryPhotoConvergesWhenLibrariesDisagreeOnPrimaryToken() throws {
        let actorId = "actor:jane"

        let storeA = try LibraryStore(at: libA)
        var a = EntityProfile(id: actorId)
        a.photoUrl = ProfileImageNaming.localPrimaryToken
        a.galleryUrls = [ProfileImageNaming.localPrimaryToken]
        try storeA.saveEntityProfile(a)
        try writePrimary(libA, actorId: actorId, bytes: 0xAA)

        let storeB = try LibraryStore(at: libB)
        var b = EntityProfile(id: actorId)
        b.photoUrl = "https://example.com/portrait.jpg"
        b.galleryUrls = ["https://example.com/portrait.jpg"]
        try storeB.saveEntityProfile(b)
        try writePrimary(libB, actorId: actorId, bytes: 0xBB)

        // One full round: plan, converge, apply everywhere.
        func syncOnce() throws {
            let ids: Set<String> = [actorId]
            let snaps = [try ActorSync.photoBearingSnapshot(of: libA, actorIds: ids),
                         try ActorSync.photoBearingSnapshot(of: libB, actorIds: ids)]
            let export = ActorSync.convergedExport(actorIds: ids, resolutions: [:], snapshots: snaps)
            try ActorSync.apply(export, to: libA)
            try ActorSync.apply(export, to: libB)
        }

        try syncOnce()

        let after = ActorSync.plan(for: [try ActorSync.snapshot(of: libA),
                                         try ActorSync.snapshot(of: libB)])
        XCTAssertTrue(after.isEmpty,
                      "one sync should converge; still differing: \(after.map(\.actorId))")

        // And the sentinel must never survive as a gallery entry where it
        // cannot be resolved.
        let finalB = try XCTUnwrap(try storeB.fetchEntityProfile(for: actorId))
        XCTAssertFalse(finalB.galleryUrls.contains(ProfileImageNaming.localPrimaryToken),
                       "the local sentinel is not a portable gallery token")
    }

    private func syncOnce(_ ids: Set<String>) throws {
        let snaps = [try ActorSync.photoBearingSnapshot(of: libA, actorIds: ids),
                     try ActorSync.photoBearingSnapshot(of: libB, actorIds: ids)]
        let export = ActorSync.convergedExport(actorIds: ids, resolutions: [:], snapshots: snaps)
        try ActorSync.apply(export, to: libA)
        try ActorSync.apply(export, to: libB)
    }

    private func stillDiffering() throws -> [String] {
        ActorSync.plan(for: [try ActorSync.snapshot(of: libA),
                             try ActorSync.snapshot(of: libB)]).map(\.actorId)
    }

    /// A photo the library HOLDS but cannot export.
    ///
    /// When `photoUrl` names a token whose primary file is absent, the image
    /// still exists on disk under its gallery name. The export used to skip
    /// that token — on the assumption the primary file covered it — so the
    /// photo was invisible to this library's exports while every other library
    /// could see it. The plan reported the gap forever and the merge rewrote
    /// the same unexportable file every pass. Observed in the field as
    /// "Renamed needs 1 photo", repeating after every approval, with no error.
    func testPhotoUnderGalleryNameIsExportedWhenPrimaryFileIsMissing() throws {
        let actorId = "actor:emily"
        let token = "https://example.com/portrait.jpg"

        // A holds the image as its PRIMARY file.
        let storeA = try LibraryStore(at: libA)
        var a = EntityProfile(id: actorId)
        a.photoUrl = "https://example.com/other.jpg"
        a.galleryUrls = ["https://example.com/other.jpg", token]
        try storeA.saveEntityProfile(a)
        try writePrimary(libA, actorId: actorId, bytes: 0x11)
        try Data(repeating: 0x22, count: 512).write(
            to: libA.appendingPathComponent(".catalog/profiles")
                .appendingPathComponent(ProfileImageNaming.galleryFileName(for: actorId, token: token)))

        // B references `token` as its primary but has NO primary file — the
        // bytes live under the gallery name instead.
        let storeB = try LibraryStore(at: libB)
        var b = EntityProfile(id: actorId)
        b.photoUrl = token
        b.galleryUrls = [token]
        try storeB.saveEntityProfile(b)
        try Data(repeating: 0x22, count: 512).write(
            to: libB.appendingPathComponent(".catalog/profiles")
                .appendingPathComponent(ProfileImageNaming.galleryFileName(for: actorId, token: token)))

        // B must advertise the photo it actually holds.
        let snapB = try ActorSync.snapshot(of: libB)
        let hashes = snapB.export.photos.filter { $0.actorId == actorId }
        XCTAssertEqual(hashes.count, 1,
                       "the photo B holds under a gallery name must be exported")

        try syncOnce([actorId])
        let remaining = try stillDiffering()
        XCTAssertTrue(remaining.isEmpty, "still differing: \(remaining)")
    }

    /// One token, two different images — a shape the libraries really produce,
    /// under an invented name.
    ///
    /// Both libraries call their primary by the same URL but the bytes differ.
    /// The merge refuses to overwrite an existing primary file, so neither
    /// hash could cross, and the plan asked for a photo in BOTH directions
    /// forever.
    func testDivergentBytesUnderOneTokenConverge() throws {
        let actorId = "actor:elly"
        let token = "https://example.com/same-name.jpg"

        for (lib, byte) in [(libA!, UInt8(0xAA)), (libB!, UInt8(0xBB))] {
            let store = try LibraryStore(at: lib)
            var p = EntityProfile(id: actorId)
            p.photoUrl = token
            p.galleryUrls = [token]
            try store.saveEntityProfile(p)
            try writePrimary(lib, actorId: actorId, bytes: byte)
        }

        try syncOnce([actorId])
        let remaining = try stillDiffering()
        XCTAssertTrue(remaining.isEmpty,
                      "one token holding two images must still converge; differing: \(remaining)")
    }

    /// The same shape under another invented name, except that here the
    /// clash is in the GALLERY rather than the primary.
    ///
    /// The gallery filename is derived from the token, and the write is guarded
    /// on the file being absent — so an incoming photo whose token is already
    /// occupied by different bytes was dropped without a word. It is genuinely
    /// missing from the destination, so the plan asked for it on every pass.
    func testGalleryTokenHoldingDifferentBytesStillConverges() throws {
        let actorId = "actor:jane"
        let shared = "https://example.com/shot.jpg"
        let profilesA = libA.appendingPathComponent(".catalog/profiles")
        let profilesB = libB.appendingPathComponent(".catalog/profiles")

        // A: `shared` is the PRIMARY, holding 0xAA.
        let storeA = try LibraryStore(at: libA)
        var a = EntityProfile(id: actorId)
        a.photoUrl = shared
        a.galleryUrls = [shared]
        try storeA.saveEntityProfile(a)
        try writePrimary(libA, actorId: actorId, bytes: 0xAA)

        // B: `shared` is a GALLERY entry holding entirely different bytes,
        // and B's primary is something else again.
        let storeB = try LibraryStore(at: libB)
        var b = EntityProfile(id: actorId)
        b.photoUrl = "https://example.com/portrait.jpg"
        b.galleryUrls = ["https://example.com/portrait.jpg", shared]
        try storeB.saveEntityProfile(b)
        try writePrimary(libB, actorId: actorId, bytes: 0xCC)
        try Data(repeating: 0xBB, count: 512).write(
            to: profilesB.appendingPathComponent(
                ProfileImageNaming.galleryFileName(for: actorId, token: shared)))

        try syncOnce([actorId])

        let remaining = try stillDiffering()
        XCTAssertTrue(remaining.isEmpty,
                      "a clashing gallery token must not swallow the photo; differing: \(remaining)")

        // Both images must survive — the fix must not have overwritten one.
        let hashesB = Set(try ActorSync.snapshot(of: libB).export.photos
            .filter { $0.actorId == actorId }.map(\.contentHash))
        let aData = Data(repeating: 0xAA, count: 512)
        let bData = Data(repeating: 0xBB, count: 512)
        XCTAssertTrue(hashesB.contains(ProfileImageNaming.sha256Hex(aData)), "A's photo arrived")
        XCTAssertTrue(hashesB.contains(ProfileImageNaming.sha256Hex(bData)), "B's own photo survived")
        _ = profilesA
    }

    /// Applying twice must not keep finding work — the property that actually
    /// failed in the field.
    func testSecondSyncFindsNothingToDo() throws {
        let actorId = "actor:jane"

        let storeA = try LibraryStore(at: libA)
        var a = EntityProfile(id: actorId)
        a.photoUrl = ProfileImageNaming.localPrimaryToken
        a.bio = "from A"
        try storeA.saveEntityProfile(a)
        try writePrimary(libA, actorId: actorId, bytes: 0xAA)

        let storeB = try LibraryStore(at: libB)
        var b = EntityProfile(id: actorId)
        b.photoUrl = "https://example.com/p.jpg"
        try storeB.saveEntityProfile(b)
        try writePrimary(libB, actorId: actorId, bytes: 0xBB)

        for _ in 0..<2 {
            let ids: Set<String> = [actorId]
            let snaps = [try ActorSync.photoBearingSnapshot(of: libA, actorIds: ids),
                         try ActorSync.photoBearingSnapshot(of: libB, actorIds: ids)]
            let export = ActorSync.convergedExport(actorIds: ids, resolutions: [:], snapshots: snaps)
            try ActorSync.apply(export, to: libA)
            try ActorSync.apply(export, to: libB)
        }

        let after = ActorSync.plan(for: [try ActorSync.snapshot(of: libA),
                                         try ActorSync.snapshot(of: libB)])
        XCTAssertTrue(after.isEmpty, "sync is not a fixed point: \(after.map(\.actorId))")
    }
}
