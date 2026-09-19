// ActorProfilePhotoFixAllTests.swift
// "Fix All Actor Profile Photos". The decision is pure and takes a directory
// listing, so every rule below is asserted without touching a disk — which is
// the point of taking the listing rather than a URL.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class ActorProfilePhotoFixAllTests: XCTestCase {

    private let id = "actor:a"
    private var safeId: String { ProfileImageNaming.safeId(for: id) }

    private func profile(photoUrl: String?, gallery: [String] = []) -> EntityProfile {
        var p = EntityProfile(id: id)
        p.photoUrl = photoUrl
        p.galleryUrls = gallery
        return p
    }

    private func gallery(_ token: String) -> String {
        ProfileImageNaming.galleryFileName(for: id, token: token)
    }

    // MARK: - The boundary this inherits from R4

    /// 🚨 A present primary is never touched, whatever `photoUrl` says — the
    /// rule the whole photo subsystem is built around.
    func testAPresentPrimaryIsLeftAlone() {
        let p = profile(photoUrl: "https://example.com/anything.jpg",
                        gallery: ["https://example.com/g.jpg"])
        let outcome = ActorProfilePhotoFixAll.plan(
            for: p, existingFiles: ["\(safeId).jpg", gallery("https://example.com/g.jpg")])
        XCTAssertEqual(outcome, .alreadyFine)
    }

    /// Even with no `photoUrl` at all: the FILE decides, not the string.
    func testAPresentPrimaryWithNoPhotoUrlIsStillAlreadyFine() {
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: nil), existingFiles: ["\(safeId).jpg"])
        XCTAssertEqual(outcome, .alreadyFine)
    }

    // MARK: - Promoting a known photo

    func testAKnownGalleryTokenIsPromotedAndKeepsNamingItsOrigin() {
        let token = "https://example.com/g1.jpg"
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: "https://example.com/dead.jpg", gallery: [token]),
            existingFiles: [gallery(token)])
        XCTAssertEqual(outcome, .promote(.init(sourceFileName: gallery(token), newPhotoUrl: token)))
    }

    /// Gallery order is the operator's order, and only entries with bytes count.
    func testTheFirstGalleryEntryWithBytesWins() {
        let missing = "https://example.com/never-downloaded.jpg"
        let present = "https://example.com/downloaded.jpg"
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: nil, gallery: [missing, present]),
            existingFiles: [gallery(present)])
        XCTAssertEqual(outcome, .promote(.init(sourceFileName: gallery(present), newPhotoUrl: present)))
    }

    // MARK: - 🚨 The case the array-driven repair could not see

    /// The whole reason this exists. A file is on disk under this performer's
    /// gallery prefix, but NOTHING in `galleryUrls` hashes to it — a re-key, a
    /// merge, or a token that was never recorded. The bytes are usable and the
    /// previous pass reported the performer as unrepairable.
    func testAnOrphanedFileIsPromotedEvenWithNoMatchingToken() {
        let orphan = "\(safeId)_deadbeef.jpg"
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: "https://example.com/dead.jpg", gallery: []),
            existingFiles: [orphan])
        XCTAssertEqual(outcome, .promote(.init(sourceFileName: orphan,
                                               newPhotoUrl: ProfileImageNaming.localPrimaryToken)))
    }

    /// ⚠️ `photoUrl` becomes the sentinel rather than a guessed URL: the file's
    /// remote origin genuinely is not known any more, and inventing one would
    /// be a claim the library cannot support.
    func testAnOrphanPromotionNeverInventsASourceUrl() {
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: "https://example.com/dead.jpg"),
            existingFiles: ["\(safeId)_abc.jpg"])
        guard case let .promote(promotion) = outcome else { return XCTFail("expected a promotion") }
        XCTAssertEqual(promotion.newPhotoUrl, ProfileImageNaming.localPrimaryToken)
        XCTAssertFalse(promotion.newPhotoUrl.hasPrefix("http"))
    }

    /// ⭐ Deterministic: several orphans must promote the SAME one every run,
    /// or re-running the tool quietly changes people's faces.
    func testSeveralOrphansPromoteTheSameOneEveryTime() {
        let files: Set<String> = ["\(safeId)_ccc.jpg", "\(safeId)_aaa.jpg", "\(safeId)_bbb.jpg"]
        for _ in 0..<5 {
            let outcome = ActorProfilePhotoFixAll.plan(for: profile(photoUrl: nil), existingFiles: files)
            XCTAssertEqual(outcome, .promote(.init(sourceFileName: "\(safeId)_aaa.jpg",
                                                   newPhotoUrl: ProfileImageNaming.localPrimaryToken)))
        }
    }

    /// A known token beats an orphan — `photoUrl` keeps its meaning where it can.
    func testAKnownTokenIsPreferredOverAnOrphan() {
        let token = "https://example.com/known.jpg"
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: nil, gallery: [token]),
            existingFiles: ["\(safeId)_aaaa.jpg", gallery(token)])
        XCTAssertEqual(outcome, .promote(.init(sourceFileName: gallery(token), newPhotoUrl: token)))
    }

    // MARK: - 🚨 Never online

    /// The answer the operator's rule requires: a performer with photos listed
    /// but none downloaded is REPORTED, never fetched.
    func testGalleryUrlsWithNothingOnDiskIsReportedNotFetched() {
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: "https://example.com/dead.jpg",
                         gallery: ["https://example.com/a.jpg", "https://example.com/b.jpg"]),
            existingFiles: [])
        XCTAssertEqual(outcome, .noLocalSource)
    }

    /// ⚠️ Another performer's files are not this performer's. A prefix match
    /// has to be anchored, or one actor's photo lands on another's card.
    func testAnotherPerformersFilesAreNeverPromoted() {
        let other = ProfileImageNaming.safeId(for: "actor:b")
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: nil), existingFiles: ["\(other).jpg", "\(other)_xyz.jpg"])
        XCTAssertEqual(outcome, .noLocalSource)
    }

    /// The `local://primary` sentinel is a placeholder for the primary file
    /// itself, so it is never treated as a gallery file to promote FROM.
    func testTheLocalPrimarySentinelIsNotTreatedAsAGalleryFile() {
        let outcome = ActorProfilePhotoFixAll.plan(
            for: profile(photoUrl: nil, gallery: [ProfileImageNaming.localPrimaryToken]),
            existingFiles: [])
        XCTAssertEqual(outcome, .noLocalSource)
    }

    // MARK: - apply

    func testApplyCopiesOntoThePrimaryNameAndSetsPhotoUrl() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixAll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let token = "https://example.com/g1.jpg"
        let source = gallery(token)
        try Data("bytes".utf8).write(to: dir.appendingPathComponent(source))

        let fixed = try ActorProfilePhotoFixAll.apply(
            .init(sourceFileName: source, newPhotoUrl: token),
            to: profile(photoUrl: nil, gallery: [token]), profilesDir: dir)

        XCTAssertEqual(fixed.photoUrl, token)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("\(safeId).jpg")),
                       Data("bytes".utf8))
        // 🚨 Copied, not moved — the gallery still lists this photo.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(source).path))
    }

    /// ⚠️ An unreadable or absent directory is an empty listing, not a throw:
    /// "nothing can be repaired here" is a finding, not a failure.
    func testAMissingProfilesDirectoryListsNothingRatherThanFailing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixAll-absent-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(ActorProfilePhotoFixAll.existingFileNames(in: missing).isEmpty)
    }

    // MARK: - Summary

    func testEveryPerformerLandsInExactlyOneBucket() {
        var summary = ActorProfilePhotoFixAll.Summary()
        summary.alreadyFine = 900
        summary.repaired = 12
        summary.noLocalSource = 460
        summary.failed = 3
        XCTAssertEqual(summary.considered, 1375)
    }

    // MARK: - 🚨 Enumerating the third state

    /// Every recorded photo with no file — the claims the library cannot
    /// currently support, which is exactly the state being eliminated.
    func testMissingPhotosListsEveryRecordedUrlWithNoFile() {
        let a = "https://example.com/a.jpg"
        let b = "https://example.com/b.jpg"
        let missing = ActorProfilePhotoFixAll.missingPhotos(
            for: profile(photoUrl: a, gallery: [a, b]), existingFiles: [])
        XCTAssertEqual(missing.map(\.token), [a, b])
    }

    /// ⭐ The primary is FIRST: a run cancelled half way should have restored
    /// faces, not filled galleries behind them.
    func testThePrimaryIsOfferedBeforeTheGallery() {
        let primary = "https://example.com/primary.jpg"
        let other = "https://example.com/other.jpg"
        let missing = ActorProfilePhotoFixAll.missingPhotos(
            for: profile(photoUrl: primary, gallery: [other, primary]), existingFiles: [])
        XCTAssertEqual(missing.first?.token, primary)
        XCTAssertTrue(missing.first?.isPrimary == true)
        XCTAssertEqual(missing.first?.fileName, "\(safeId).jpg")
        XCTAssertEqual(missing.count, 2, "and the primary is not offered twice")
    }

    func testPhotosAlreadyOnDiskAreNotListed() {
        let a = "https://example.com/a.jpg"
        let b = "https://example.com/b.jpg"
        let missing = ActorProfilePhotoFixAll.missingPhotos(
            for: profile(photoUrl: nil, gallery: [a, b]), existingFiles: [gallery(a)])
        XCTAssertEqual(missing.map(\.token), [b])
    }

    func testTheSentinelIsNeverOfferedForDownload() {
        let missing = ActorProfilePhotoFixAll.missingPhotos(
            for: profile(photoUrl: ProfileImageNaming.localPrimaryToken,
                         gallery: [ProfileImageNaming.localPrimaryToken]),
            existingFiles: [])
        XCTAssertTrue(missing.isEmpty, "the sentinel names the primary file, not a remote photo")
    }

    // MARK: - 🚨 Dropping only what is definitively gone

    func testAGoneTokenIsRemovedFromTheGallery() {
        let dead = "https://example.com/dead.jpg"
        let alive = "https://example.com/alive.jpg"
        let updated = ActorProfilePhotoFixAll.dropping(
            [dead], from: profile(photoUrl: alive, gallery: [dead, alive]))
        XCTAssertEqual(updated?.galleryUrls, [alive])
        XCTAssertEqual(updated?.photoUrl, alive, "a living primary is untouched")
    }

    /// ⚠️ A gone primary is CLEARED, never repointed here. Choosing a
    /// replacement would be a second, hidden expression of "which photo is the
    /// primary" — `plan(for:existingFiles:)` owns that, against the files that
    /// then exist.
    func testAGonePrimaryIsClearedRatherThanRepointed() {
        let dead = "https://example.com/dead.jpg"
        let other = "https://example.com/other.jpg"
        let updated = ActorProfilePhotoFixAll.dropping(
            [dead], from: profile(photoUrl: dead, gallery: [dead, other]))
        XCTAssertNil(updated?.photoUrl)
        XCTAssertEqual(updated?.galleryUrls, [other])
    }

    /// ⭐ No change means no write. A pass over a library where nothing is gone
    /// must not rewrite every profile row it read.
    func testNothingGoneMeansNoUpdate() {
        XCTAssertNil(ActorProfilePhotoFixAll.dropping(
            [], from: profile(photoUrl: "https://example.com/a.jpg")))
        XCTAssertNil(ActorProfilePhotoFixAll.dropping(
            ["https://example.com/not-in-this-profile.jpg"],
            from: profile(photoUrl: "https://example.com/a.jpg",
                          gallery: ["https://example.com/a.jpg"])))
    }


    // MARK: - reconcile — the unit of the invariant

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reconcile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testReconcileDownloadsEveryMissingPhoto() async {
        let a = "https://example.com/a.jpg"
        let b = "https://example.com/b.jpg"
        let outcome = await ActorProfilePhotoFixAll.reconcile(
            profile(photoUrl: a, gallery: [a, b]),
            existingFiles: [], profilesDir: tempDir(),
            download: { _, _ in .downloaded })

        XCTAssertEqual(outcome.downloaded, 2)
        XCTAssertNil(outcome.updatedProfile, "nothing gone means nothing to write")
        XCTAssertEqual(outcome.filesAdded.count, 2)
    }

    /// ⭐ The face-first pass: one photo is enough, and because the primary is
    /// offered first it is the RIGHT one.
    func testReconcileStopsAfterTheFirstDownloadWhenAsked() async {
        let primary = "https://example.com/primary.jpg"
        let other = "https://example.com/other.jpg"
        let attempts = Counter()
        let outcome = await ActorProfilePhotoFixAll.reconcile(
            profile(photoUrl: primary, gallery: [other]),
            existingFiles: [], profilesDir: tempDir(),
            stopAfterFirstDownload: true,
            download: { token, _ in
                attempts.record(token)
                return .downloaded
            })

        XCTAssertEqual(outcome.downloaded, 1)
        XCTAssertEqual(attempts.tokens, [primary], "the primary, and then it stops")
    }

    /// ⚠️ A failure does NOT stop the face-first pass — the next photo is the
    /// whole point of having more than one.
    func testAFailureDoesNotEndTheFaceFirstPass() async {
        let dead = "https://example.com/dead.jpg"
        let good = "https://example.com/good.jpg"
        let outcome = await ActorProfilePhotoFixAll.reconcile(
            profile(photoUrl: dead, gallery: [good]),
            existingFiles: [], profilesDir: tempDir(),
            stopAfterFirstDownload: true,
            download: { token, _ in
                token == dead ? .gone : .downloaded
            })

        XCTAssertEqual(outcome.downloaded, 1)
        XCTAssertEqual(outcome.dropped, 1)
        XCTAssertNil(outcome.updatedProfile?.photoUrl, "the dead primary is cleared")
        XCTAssertEqual(outcome.updatedProfile?.galleryUrls, [good])
    }

    /// 🚨 The data-loss boundary, at the level callers actually use.
    func testAnUnreachableSourceChangesNothingAboutTheProfile() async {
        let a = "https://example.com/a.jpg"
        let outcome = await ActorProfilePhotoFixAll.reconcile(
            profile(photoUrl: a, gallery: [a]),
            existingFiles: [], profilesDir: tempDir(),
            download: { _, _ in .unavailable })

        XCTAssertEqual(outcome.unavailable, 1)
        XCTAssertEqual(outcome.downloaded, 0)
        XCTAssertNil(outcome.updatedProfile, "a bad connection must never rewrite a profile")
    }

    func testPhotosAlreadyLocalAreNeverFetched() async {
        let a = "https://example.com/a.jpg"
        let attempts = Counter()
        let outcome = await ActorProfilePhotoFixAll.reconcile(
            profile(photoUrl: nil, gallery: [a]),
            existingFiles: [gallery(a)], profilesDir: tempDir(),
            download: { token, _ in
                attempts.record(token)
                return .downloaded
            })

        XCTAssertEqual(outcome.downloaded, 0)
        XCTAssertTrue(attempts.tokens.isEmpty, "re-running must not re-download the library")
    }

    /// ⚠️ A `@Sendable` downloader cannot mutate a captured var under Swift 6.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func record(_ token: String) { lock.lock(); seen.append(token); lock.unlock() }
        var tokens: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

}
