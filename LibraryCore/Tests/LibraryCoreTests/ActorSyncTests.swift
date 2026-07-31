import XCTest
@testable import LibraryCore

/// The actor-sync engine: pure planning (missing / gap-fill / photo-and-list
/// adds / TRUE conflicts, with the multi-value subset-vs-conflict rule),
/// conflict resolutions incl. Keep Both, converged-export building (skip ⇒
/// nil ⇒ destination keeps its own value), and an end-to-end apply through
/// the real merge engine against two temp libraries.
final class ActorSyncTests: XCTestCase {

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
        XCTAssertEqual(plans.map(\.actorId), ["actor:jane"])
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
        XCTAssertEqual(Set(plans.map(\.actorId)), ["actor:jane", "actor:bailey"])
        XCTAssertEqual(plans.first { $0.actorId == "actor:jane" }?.conflicts.map(\.field), [.hairColor])

        let export = ActorSync.convergedExport(
            actorIds: ["actor:jane", "actor:bailey"],
            resolutions: ["actor:jane": [.hairColor: .keepBoth]],
            snapshots: snapshots)
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
