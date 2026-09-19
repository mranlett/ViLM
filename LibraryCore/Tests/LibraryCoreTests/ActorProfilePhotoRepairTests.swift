import XCTest
@testable import LibraryCore

/// #97. Resetting a broken profile photo is real file I/O over real actor
/// data, so these use real temp files rather than synthetic fixtures — the
/// same reasoning `VideoTransferServiceTests` gives for its own temp dir.
final class ActorProfilePhotoRepairTests: XCTestCase {

    private var profilesDir: URL!

    override func setUpWithError() throws {
        profilesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActorProfilePhotoRepairTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: profilesDir)
    }

    private func write(_ bytes: String, fileName: String) throws {
        try Data(bytes.utf8).write(to: profilesDir.appendingPathComponent(fileName))
    }

    private func profile(id: String = "actor:a", photoUrl: String?, gallery: [String]) -> EntityProfile {
        var p = EntityProfile(id: id)
        p.photoUrl = photoUrl
        p.galleryUrls = gallery
        return p
    }

    // MARK: - worklist

    /// The rule this whole feature exists to protect: a primary that already
    /// resolves locally is never touched, whatever `photoUrl` says.
    func testAWorkingPrimaryIsNeverACandidate() throws {
        try write("primary bytes", fileName: ProfileImageNaming.primaryFileName(for: "actor:a"))
        let p = profile(photoUrl: "https://example.com/old.jpg", gallery: ["https://example.com/old.jpg"])

        XCTAssertTrue(ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir).isEmpty)
    }

    /// The user's actual 450+ case: the assignment was lost (empty
    /// `photoUrl`), but the gallery photo was already downloaded.
    func testAnEmptyPhotoUrlWithADownloadedGalleryPhotoIsRepaired() throws {
        let token = "https://example.com/g1.jpg"
        try write("gallery bytes", fileName: ProfileImageNaming.galleryFileName(for: "actor:a", token: token))
        let p = profile(photoUrl: nil, gallery: [token])

        let worklist = ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir)
        XCTAssertEqual(worklist.map(\.promote), [token])
    }

    /// `photoUrl` pointing at something is not the same as it resolving to a
    /// file — the primary file itself decides, per the operator's refinement.
    func testANonEmptyPhotoUrlWithNoLocalFileIsStillRepaired() throws {
        let token = "https://example.com/g1.jpg"
        try write("gallery bytes", fileName: ProfileImageNaming.galleryFileName(for: "actor:a", token: token))
        let p = profile(photoUrl: "https://example.com/dead-link.jpg", gallery: [token])

        let worklist = ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir)
        XCTAssertEqual(worklist.map(\.promote), [token])
    }

    /// Gallery order is respected, but only among entries actually on disk —
    /// an entry never downloaded is skipped rather than chosen and failing.
    func testTheFirstDownloadedGalleryEntryIsChosenSkippingUndownloadedOnes() throws {
        let neverDownloaded = "https://example.com/never-fetched.jpg"
        let downloaded = "https://example.com/g2.jpg"
        try write("gallery bytes", fileName: ProfileImageNaming.galleryFileName(for: "actor:a", token: downloaded))
        let p = profile(photoUrl: nil, gallery: [neverDownloaded, downloaded])

        let worklist = ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir)
        XCTAssertEqual(worklist.map(\.promote), [downloaded])
    }

    /// ⚠️ The rule this whole feature exists to respect: never go online.
    /// Nothing locally downloaded means nothing to repair with — reported as
    /// unfixed, not fetched.
    func testNothingDownloadedProducesNoCandidate() throws {
        let p = profile(photoUrl: nil, gallery: ["https://example.com/never-fetched.jpg"])

        XCTAssertTrue(ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir).isEmpty)
    }

    func testAProfileWithNoGalleryAtAllProducesNoCandidate() {
        let p = profile(photoUrl: nil, gallery: [])
        XCTAssertTrue(ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir).isEmpty)
    }

    // MARK: - repair

    func testRepairCopiesTheGalleryFileToThePrimaryPathAndSetsPhotoUrl() throws {
        let token = "https://example.com/g1.jpg"
        try write("gallery bytes", fileName: ProfileImageNaming.galleryFileName(for: "actor:a", token: token))
        let p = profile(photoUrl: nil, gallery: [token])
        let candidate = try XCTUnwrap(ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir).first)

        let repaired = try ActorProfilePhotoRepair.repair(candidate, profilesDir: profilesDir)

        XCTAssertEqual(repaired.photoUrl, token)
        let primaryFile = profilesDir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: "actor:a"))
        XCTAssertEqual(try Data(contentsOf: primaryFile), Data("gallery bytes".utf8))
        // ⚠️ The gallery copy survives — this promotes, it does not move. A
        // profile whose gallery still lists this token must still find its file.
        let galleryFile = profilesDir.appendingPathComponent(
            ProfileImageNaming.galleryFileName(for: "actor:a", token: token))
        XCTAssertTrue(FileManager.default.fileExists(atPath: galleryFile.path))
    }

    /// A working primary is repaired over silently only via `worklist`
    /// refusing to produce a candidate — `repair` itself has no re-check, by
    /// design (same split as `RelocationMover`: the plan is the safety
    /// property). This pins that `repair` uses the injected seam rather than
    /// touching the real filesystem when a caller supplies one.
    func testRepairUsesTheInjectedCopySeam() throws {
        let token = "https://example.com/g1.jpg"
        let p = profile(photoUrl: nil, gallery: [token])
        let candidate = ActorProfilePhotoRepair.Candidate(profile: p, promote: token)

        var seen: (URL, URL)?
        _ = try ActorProfilePhotoRepair.repair(candidate, profilesDir: profilesDir) { source, destination in
            seen = (source, destination)
        }

        XCTAssertEqual(seen?.0, profilesDir.appendingPathComponent(
            ProfileImageNaming.galleryFileName(for: "actor:a", token: token)))
        XCTAssertEqual(seen?.1, profilesDir.appendingPathComponent(
            ProfileImageNaming.primaryFileName(for: "actor:a")))
        // No file was actually written — the real filesystem was never touched.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: profilesDir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: "actor:a")).path))
    }

    // MARK: - 🚨 The cost fix: existence, not hashes

    /// The mapping this function used to get from `ActorPhotoScanner.measure`,
    /// asserted directly now that it is expressed here: a gallery entry that
    /// IS the `photoUrl` resolves to the primary file, which has already been
    /// ruled absent — so it is never probed again under a hashed gallery name,
    /// and a later gallery entry is what gets promoted.
    func testAGalleryEntryEqualToThePhotoUrlIsNotProbedAsAGalleryFile() throws {
        let primary = "https://example.com/a.jpg"
        let other = "https://example.com/b.jpg"
        // Only the SECOND entry has bytes. If the first were probed under its
        // hashed gallery name it would still miss, so the discriminating fact
        // is which paths get looked at — recorded below.
        try write("b bytes", fileName: ProfileImageNaming.galleryFileName(for: "actor:a", token: other))
        let p = profile(photoUrl: primary, gallery: [primary, other])

        var probed: [String] = []
        let work = ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir) { url in
            probed.append(url.lastPathComponent)
            return FileManager.default.fileExists(atPath: url.path)
        }

        XCTAssertEqual(work.map(\.promote), [other])
        XCTAssertFalse(
            probed.contains(ProfileImageNaming.galleryFileName(for: "actor:a", token: primary)),
            "the photoUrl token maps to the primary file and must not be probed twice")
    }

    /// ⚠️ An empty `photoUrl` equals no token, so the primary file is never
    /// consulted — matching what `measure` did, where `isPrimary` was
    /// `photoUrl == token` and an empty string matched nothing.
    func testAnEmptyPhotoUrlNeverConsultsThePrimaryFile() throws {
        let token = "https://example.com/g.jpg"
        try write("g bytes", fileName: ProfileImageNaming.galleryFileName(for: "actor:a", token: token))
        let p = profile(photoUrl: "", gallery: [token])

        var probed: [String] = []
        _ = ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir) { url in
            probed.append(url.lastPathComponent)
            return FileManager.default.fileExists(atPath: url.path)
        }

        XCTAssertFalse(probed.contains(ProfileImageNaming.primaryFileName(for: "actor:a")))
    }

    /// ⭐ The performance claim, stated as a fact a test can hold: deciding
    /// consults each candidate file AT MOST once and never reads its contents.
    /// The previous implementation read every byte of every photo and hashed
    /// it twice to answer this same question.
    func testDecidingProbesEachFileAtMostOnce() throws {
        let tokens = (0..<5).map { "https://example.com/\($0).jpg" }
        for token in tokens.dropFirst(4) {
            try write("bytes", fileName: ProfileImageNaming.galleryFileName(for: "actor:a", token: token))
        }
        let p = profile(photoUrl: "https://example.com/primary.jpg", gallery: tokens)

        var probed: [String] = []
        _ = ActorProfilePhotoRepair.worklist([p], profilesDir: profilesDir) { url in
            probed.append(url.lastPathComponent)
            return FileManager.default.fileExists(atPath: url.path)
        }

        XCTAssertEqual(probed.count, Set(probed).count, "no file is looked at twice")
        XCTAssertLessThanOrEqual(probed.count, tokens.count + 1, "primary plus each gallery entry once")
    }

}
