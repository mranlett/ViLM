import XCTest
@testable import LibraryCore

/// The actor-sync engine: pure planning (missing / gap-fill / photo-and-list
/// adds / TRUE conflicts, with the multi-value subset-vs-conflict rule),
/// conflict resolutions incl. Keep Both, converged-export building (skip ⇒
/// nil ⇒ destination keeps its own value), and an end-to-end apply through
/// the real merge engine against two temp libraries.
final class ActorSyncTests: XCTestCase {

    /// ⚠️ `ActorSyncPlan.actorId` is an IDENTITY key, not a profile id.
    /// It changed when sync stopped keying on the id: two re-keyed libraries
    /// call one person by different uids, so the id cannot be what the plan is
    /// about. Derived here rather than written out, because the key contains
    /// U+001F separators that are invisible in a diff.
    private func key(_ legacyId: String) -> String {
        ActorSync.syncKey(EntityProfile(id: legacyId))
    }


    private let main = URL(fileURLWithPath: "/tmp/main-lib")
    private let portable = URL(fileURLWithPath: "/tmp/portable-lib")

    private func snapshot(_ url: URL, profiles: [EntityProfile], photos: [ExportedPhoto] = []) -> ActorSync.LibrarySnapshot {
        ActorSync.LibrarySnapshot(
            url: url,
            export: ActorLibraryExport(formatVersion: 1, exportedAt: Date(), profiles: profiles, photos: photos))
    }

    private func photo(_ actorId: String, hash: String, token: String? = nil, primary: Bool = false) -> ExportedPhoto {
        ExportedPhoto(actorId: actorId, isPrimary: primary, sourceToken: token,
                      contentHash: hash, fileExtension: "jpg", data: Data(hash.utf8))
    }

    // MARK: - Planning

    func testIdenticalActorsNeedNoSync() {
        let jane = EntityProfile(id: "actor:jane", bio: "same", hairColor: "Brown", tags: ["tag:x"])
        let plans = ActorSync.plan(for: [
            snapshot(main, profiles: [jane]),
            snapshot(portable, profiles: [jane]),
        ])
        XCTAssertTrue(plans.isEmpty)
    }

    func testMissingActorIsPlannedForTheLibraryLackingIt() {
        let plans = ActorSync.plan(for: [
            snapshot(main, profiles: [EntityProfile(id: "actor:jane", bio: "b")]),
            snapshot(portable, profiles: []),
        ])
        XCTAssertEqual(plans.map(\.actorId), [key("actor:jane")])
        XCTAssertEqual(plans[0].missingFrom, [portable])
        XCTAssertTrue(plans[0].conflicts.isEmpty)
    }

    func testBlankFillsCountBothDirections() {
        // MAIN knows the bio; Portable knows the rating — each fills the other.
        let plans = ActorSync.plan(for: [
            snapshot(main, profiles: [EntityProfile(id: "actor:jane", bio: "from main")]),
            snapshot(portable, profiles: [EntityProfile(id: "actor:jane", rating: 4)]),
        ])
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].blankFills[main], 1, "main gets the rating")
        XCTAssertEqual(plans[0].blankFills[portable], 1, "portable gets the bio")
        XCTAssertTrue(plans[0].conflicts.isEmpty)
    }

    func testScalarConflictSurfacesBothValuesWithTheirLibraries() {
        let plans = ActorSync.plan(for: [
            snapshot(main, profiles: [EntityProfile(id: "actor:jane", birthYear: 1990)]),
            snapshot(portable, profiles: [EntityProfile(id: "actor:jane", birthYear: 1991)]),
        ])
        XCTAssertEqual(plans[0].conflicts.count, 1)
        let conflict = plans[0].conflicts[0]
        XCTAssertEqual(conflict.field, .birthYear)
        XCTAssertFalse(conflict.supportsKeepBoth, "a person has one birth year")
        XCTAssertEqual(conflict.values.map(\.value), ["1990", "1991"])
        XCTAssertEqual(conflict.values[0].libraries, [main])
        XCTAssertEqual(conflict.values[1].libraries, [portable])
    }

    func testMultiValueSubsetIsAGapNotAConflict() {
        // {Brown} ⊂ {Brown, Red}: one side just knows more — extend, don't ask.
        let plans = ActorSync.plan(for: [
            snapshot(main, profiles: [EntityProfile(id: "actor:jane", hairColor: "Brown")]),
            snapshot(portable, profiles: [EntityProfile(id: "actor:jane", hairColor: "Brown, Red")]),
        ])
        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].conflicts.isEmpty)
        XCTAssertEqual(plans[0].blankFills[main], 1, "main extends to the superset")
        XCTAssertNil(plans[0].blankFills[portable])
    }

    func testMultiValueDisjointIsAConflictWithKeepBoth() {
        let plans = ActorSync.plan(for: [
            snapshot(main, profiles: [EntityProfile(id: "actor:jane", hairColor: "Brown")]),
            snapshot(portable, profiles: [EntityProfile(id: "actor:jane", hairColor: "Red")]),
        ])
        XCTAssertEqual(plans[0].conflicts.count, 1)
        let conflict = plans[0].conflicts[0]
        XCTAssertEqual(conflict.field, .hairColor)
        XCTAssertTrue(conflict.supportsKeepBoth)
        XCTAssertEqual(conflict.keepBothValue, "Brown, Red")
    }

    func testListAndPhotoAddsAreCounted() {
        let plans = ActorSync.plan(for: [
            snapshot(main,
                     profiles: [EntityProfile(id: "actor:jane", tags: ["tag:a", "tag:b"], akas: ["JJ"])],
                     photos: [photo("actor:jane", hash: "h1"), photo("actor:jane", hash: "h2")]),
            snapshot(portable,
                     profiles: [EntityProfile(id: "actor:jane", tags: ["tag:a"])],
                     photos: [photo("actor:jane", hash: "h2"), photo("actor:jane", hash: "h3")]),
        ])
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].listAdds[portable], 2, "tag:b + AKA JJ")
        XCTAssertNil(plans[0].listAdds[main])
        XCTAssertEqual(plans[0].photoAdds[main], 1, "h3 is new to main")
        XCTAssertEqual(plans[0].photoAdds[portable], 1, "h1 is new to portable")
    }

    // MARK: - Convergence

    func testConvergedUseResolutionSetsTheValueEverywhere() {
        let export = ActorSync.convergedExport(
            actorIds: ["actor:jane"],
            resolutions: ["actor:jane": [.birthYear: .use("1990")]],
            snapshots: [
                snapshot(main, profiles: [EntityProfile(id: "actor:jane", birthYear: 1990)]),
                snapshot(portable, profiles: [EntityProfile(id: "actor:jane", birthYear: 1991)]),
            ])
        XCTAssertEqual(export.profiles.first?.birthYear, 1990)
    }

    func testConvergedSkipEncodesNilSoDestinationsKeepTheirOwn() {
        let export = ActorSync.convergedExport(
            actorIds: ["actor:jane"],
            resolutions: [:],   // unresolved conflict defaults to .skip
            snapshots: [
                snapshot(main, profiles: [EntityProfile(id: "actor:jane", bio: "main bio", rating: 5)]),
                snapshot(portable, profiles: [EntityProfile(id: "actor:jane", bio: "portable bio")]),
            ])
        let converged = export.profiles.first
        XCTAssertNil(converged?.bio, "skipped conflict must not overwrite either side")
        XCTAssertEqual(converged?.rating, 5, "non-conflicted scalar still converges")
    }

    func testConvergedKeepBothJoinsTheSets() {
        let export = ActorSync.convergedExport(
            actorIds: ["actor:jane"],
            resolutions: ["actor:jane": [.hairColor: .keepBoth]],
            snapshots: [
                snapshot(main, profiles: [EntityProfile(id: "actor:jane", hairColor: "Brown")]),
                snapshot(portable, profiles: [EntityProfile(id: "actor:jane", hairColor: "Red, Auburn")]),
            ])
        XCTAssertEqual(export.profiles.first?.hairColor, "Brown, Red, Auburn")
    }

    func testConvergedUnionsListsAndDedupesPhotosByHash() {
        let export = ActorSync.convergedExport(
            actorIds: ["actor:jane"],
            resolutions: [:],
            snapshots: [
                snapshot(main,
                         profiles: [EntityProfile(id: "actor:jane", tags: ["tag:a"], akas: ["JJ"])],
                         photos: [photo("actor:jane", hash: "h1")]),
                snapshot(portable,
                         profiles: [EntityProfile(id: "actor:jane", tags: ["tag:b"])],
                         photos: [photo("actor:jane", hash: "h1"), photo("actor:jane", hash: "h2")]),
            ])
        XCTAssertEqual(export.profiles.first?.tags, ["tag:a", "tag:b"])
        XCTAssertEqual(export.profiles.first?.akas, ["JJ"])
        XCTAssertEqual(export.photos.map(\.contentHash).sorted(), ["h1", "h2"],
                       "same content in both libraries ships once")
    }

    // MARK: - Regression: metadata synced before files (user report)

    func testPhotosCopyEvenWhenTokenListsAlreadyMatch() throws {
        // The user's exact scenario: both libraries already hold IDENTICAL
        // actor records (photoUrl + galleryUrls token lists synced earlier),
        // but the photo FILES each live in only one library. The merge used
        // to gate file writes on token membership — "token present ⇒ file
        // present" — silently skipping every copy. Writes must be gated on
        // the FILE's existence.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActorSyncPhotoRegression-\(UUID().uuidString)", isDirectory: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: tmp)
        }
        let libA = tmp.appendingPathComponent("A", isDirectory: true)
        let libB = tmp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: libA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libB, withIntermediateDirectories: true)

        let primaryToken = "https://x/primary.jpg"
        let galleryToken = "https://x/gallery.jpg"
        // Identical records in BOTH libraries — including the token lists.
        let record = EntityProfile(id: "actor:jane", bio: "same everywhere",
                                   photoUrl: primaryToken,
                                   galleryUrls: [primaryToken, galleryToken])
        try LibraryStore(at: libA).saveEntityProfile(record)
        try LibraryStore(at: libB).saveEntityProfile(record)

        // Files: A has the PRIMARY file only; B has the GALLERY file only.
        let dirA = libA.appendingPathComponent(".catalog/profiles")
        let dirB = libB.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data([1, 1]).write(to: dirA.appendingPathComponent(
            ProfileImageNaming.primaryFileName(for: "actor:jane")))
        try Data([2, 2]).write(to: dirB.appendingPathComponent(
            ProfileImageNaming.galleryFileName(for: "actor:jane", token: galleryToken)))

        // The plan sees the photo gap even though the metadata is identical…
        let snapshots = [try ActorSync.snapshot(of: libA), try ActorSync.snapshot(of: libB)]
        let plans = ActorSync.plan(for: snapshots)
        XCTAssertEqual(plans.map(\.actorId), [key("actor:jane")])
        XCTAssertTrue(plans[0].conflicts.isEmpty, "identical metadata ⇒ conflict-free")
        XCTAssertEqual(plans[0].photoAdds[libA], 1)
        XCTAssertEqual(plans[0].photoAdds[libB], 1)

        // …and applying actually lands the FILES on both sides.
        //
        // Photo BYTES come from a photo-bearing snapshot scoped to the actors
        // being synced, mirroring what the sync screen does. Planning
        // snapshots deliberately carry hashes only — loading every photo in
        // the library was what exhausted memory and killed the app mid-sync.
        let photoSnapshots = [
            try ActorSync.photoBearingSnapshot(of: libA, actorIds: ["actor:jane"]),
            try ActorSync.photoBearingSnapshot(of: libB, actorIds: ["actor:jane"]),
        ]
        let export = ActorSync.convergedExport(
            actorIds: ["actor:jane"], resolutions: [:], snapshots: photoSnapshots)
        try ActorSync.apply(export, to: libA)
        try ActorSync.apply(export, to: libB)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.appendingPathComponent(
            ProfileImageNaming.galleryFileName(for: "actor:jane", token: galleryToken)).path),
            "A received the gallery file it was missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent(
            ProfileImageNaming.primaryFileName(for: "actor:jane")).path),
            "B received the primary file its record already referenced")

        let after = ActorSync.plan(for: [try ActorSync.snapshot(of: libA), try ActorSync.snapshot(of: libB)])
        XCTAssertTrue(after.isEmpty, "photo convergence complete: \(after.map(\.actorId))")
    }

    // MARK: - End-to-end apply (real stores, real photo files)

    func testApplyConvergesTwoRealLibraries() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActorSyncE2E-\(UUID().uuidString)", isDirectory: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: tmp)
        }
        let libA = tmp.appendingPathComponent("A", isDirectory: true)
        let libB = tmp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: libA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libB, withIntermediateDirectories: true)

        // A: jane with bio "Brown" hair and a gallery photo; B: jane with a
        // rating, "Red" hair, and her own photo. Bailey exists only in A.
        let storeA = try LibraryStore(at: libA)
        let storeB = try LibraryStore(at: libB)
        let tokenA = "https://x/a.jpg", tokenB = "https://x/b.jpg"
        try storeA.saveEntityProfile(EntityProfile(
            id: "actor:jane", bio: "world traveler", hairColor: "Brown", galleryUrls: [tokenA]))
        try storeA.saveEntityProfile(EntityProfile(id: "actor:bailey", bio: "only in A"))
        try storeB.saveEntityProfile(EntityProfile(
            id: "actor:jane", hairColor: "Red", rating: 4, galleryUrls: [tokenB]))
        let dirA = libA.appendingPathComponent(".catalog/profiles")
        let dirB = libB.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data([1, 1]).write(to: dirA.appendingPathComponent(
            ProfileImageNaming.galleryFileName(for: "actor:jane", token: tokenA)))
        try Data([2, 2]).write(to: dirB.appendingPathComponent(
            ProfileImageNaming.galleryFileName(for: "actor:jane", token: tokenB)))

        // Plan from real snapshots, resolve hair with Keep Both, apply to both.
        let snapshots = [try ActorSync.snapshot(of: libA), try ActorSync.snapshot(of: libB)]
        let plans = ActorSync.plan(for: snapshots)
        XCTAssertEqual(Set(plans.map(\.actorId)), [key("actor:jane"), key("actor:bailey")])
        XCTAssertEqual(plans.first { $0.actorId == key("actor:jane") }?.conflicts.map(\.field), [.hairColor])

        // Photo bytes are re-read for just these actors; see the note in
        // testPhotosCopyEvenWhenTokenListsAlreadyMatch.
        let ids: Set<String> = ["actor:jane", "actor:bailey"]
        let photoSnapshots = [
            try ActorSync.photoBearingSnapshot(of: libA, actorIds: ids),
            try ActorSync.photoBearingSnapshot(of: libB, actorIds: ids),
        ]
        let export = ActorSync.convergedExport(
            actorIds: ids,
            resolutions: ["actor:jane": [.hairColor: .keepBoth]],
            snapshots: photoSnapshots)
        try ActorSync.apply(export, to: libA)
        try ActorSync.apply(export, to: libB)

        // Both libraries converged: bio + rating everywhere, hair kept both,
        // bailey copied to B, and each library holds BOTH photo files.
        for lib in [libA, libB] {
            let store = try LibraryStore(at: lib)
            let jane = try XCTUnwrap(store.fetchEntityProfile(for: "actor:jane"))
            XCTAssertEqual(jane.bio, "world traveler")
            XCTAssertEqual(jane.rating, 4)
            XCTAssertEqual(Set(ActorSync.splitList(jane.hairColor ?? "")), ["Brown", "Red"])
            XCTAssertEqual(try store.fetchEntityProfile(for: "actor:bailey")?.bio, "only in A")

            let dir = lib.appendingPathComponent(".catalog/profiles")
            let photoFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            XCTAssertEqual(photoFiles.filter { $0.hasPrefix("actor_jane_") }.count, 2,
                           "\(lib.lastPathComponent) holds both gallery photos")
        }

        // Re-planning after the sync finds nothing left to do.
        let after = ActorSync.plan(for: [try ActorSync.snapshot(of: libA), try ActorSync.snapshot(of: libB)])
        XCTAssertTrue(after.isEmpty, "post-sync libraries are in sync: \(after.map(\.actorId))")
    }
}
