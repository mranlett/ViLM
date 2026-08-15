// PerformerProfileFilmsTests.swift
// #64 — the films shown under a claimant are THAT profile's own.
//
// 🚨 The property under test is a refusal to fold. `ActorCredits` folds an alias
// into its owner, which is correct when asking "what is this person in". The
// merge screen asks a different question — "are these two records the same
// person?" — and the two records it compares are an alias and its claimant. Fold
// there and both sides draw the same filmography, which does not merely fail to
// help: it manufactures agreement between the two things the operator is being
// asked to tell apart.

import XCTest
@testable import LibraryCore

final class PerformerProfileFilmsTests: XCTestCase {

    private func makeStore() throws -> (LibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try LibraryStore(at: dir), dir)
    }

    private func asset(_ actors: [String], name: String) throws -> Asset {
        Asset(relativePath: "\(name).mp4", fileName: "\(name).mp4",
              tags: actors.map { "actor:\($0)" }, videoName: name)
    }

    /// 🚨 The one that matters. "Vera Example" lists "V. Example" as an alias —
    /// the exact shape this screen exists to resolve — and the two are separate
    /// profiles. Each keeps its own film.
    func testAClaimantsFilmsDoNotAbsorbItsAliasesFilms() throws {
        let (store, dir) = try makeStore()
        defer { LibraryStore.evictCachedConnection(forLibraryAt: dir)
                try? FileManager.default.removeItem(at: dir) }

        var canonical = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                      displayName: "Vera Example")
        canonical.akas = ["V. Example"]
        let alias = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                  displayName: "V. Example")
        try store.saveEntityProfile(canonical)
        try store.saveEntityProfile(alias)

        let hers = try asset(["Vera Example"], name: "Harbour Nights")
        let theAliass = try asset(["V. Example"], name: "The Long Way")
        try store.insertAsset(hers)
        try store.insertAsset(theAliass)

        let films = try store.videoIdsByPerformerProfile()

        XCTAssertEqual(films[canonical.id], [hers.id.uuidString],
                       "the claimant must show only its own film, or the comparison is rigged")
        XCTAssertEqual(films[alias.id], [theAliass.id.uuidString])

        // ⭐ And the contrast that makes the point: the AKA-folding rule, asked
        // the same question, credits BOTH films to the canonical profile. That
        // is right for a profile page and wrong for this screen.
        let folded = ActorCredits.byActor(
            assets: [hers, theAliass],
            profiles: EntityProfileIndex([canonical, alias]))
        XCTAssertEqual(folded["Vera Example"]?.count, 2,
                       "if this ever equals 1, the two rules have converged and "
                       + "the reason for selecting by profile id has gone")
    }

    /// ⚠️ The strip and the number printed beside it come from ONE union, so a
    /// row reading "3 videos" can never expand to show two.
    func testTheFilmSetAgreesWithTheVideoCountTheAuditReports() throws {
        let (store, dir) = try makeStore()
        defer { LibraryStore.evictCachedConnection(forLibraryAt: dir)
                try? FileManager.default.removeItem(at: dir) }

        var canonical = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                      displayName: "Vera Example")
        canonical.akas = ["V. Example"]
        let alias = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                  displayName: "V. Example")
        try store.saveEntityProfile(canonical)
        try store.saveEntityProfile(alias)

        for n in 1...3 { try store.insertAsset(try asset(["Vera Example"], name: "Hers \(n)")) }
        try store.insertAsset(try asset(["V. Example"], name: "Theirs"))

        let films = try store.videoIdsByPerformerProfile()
        let candidates = try store.auditAliasSplits()

        XCTAssertFalse(candidates.isEmpty, "the fixture must produce a candidate")
        for candidate in candidates {
            for claimant in [candidate.alias] + candidate.claimants {
                XCTAssertEqual(films[claimant.id]?.count ?? 0, claimant.videoCount,
                               "\(claimant.displayName): the strip would contradict the count")
            }
        }
    }

    /// A performer credited on the same video twice — canonically and by an
    /// alias spelling that is its own profile — still counts that video once
    /// for each profile, not twice for either.
    func testOneVideoCountsOncePerProfile() throws {
        let (store, dir) = try makeStore()
        defer { LibraryStore.evictCachedConnection(forLibraryAt: dir)
                try? FileManager.default.removeItem(at: dir) }

        var canonical = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                      displayName: "Vera Example")
        canonical.akas = ["V. Example"]
        let alias = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                  displayName: "V. Example")
        try store.saveEntityProfile(canonical)
        try store.saveEntityProfile(alias)

        let both = try asset(["Vera Example", "V. Example"], name: "Coast Road")
        try store.insertAsset(both)

        let films = try store.videoIdsByPerformerProfile()
        XCTAssertEqual(films[canonical.id]?.count, 1)
        XCTAssertEqual(films[alias.id]?.count, 1)
    }
}
