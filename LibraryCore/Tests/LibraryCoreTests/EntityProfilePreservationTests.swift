import XCTest
@testable import LibraryCore

/// Guards the paths that COPY a profile rather than read one.
///
/// This model has lost data three times the same way: a field is added, and one
/// of the several places that rebuilds a profile field-by-field is not updated.
/// Every field has a default, so the omission compiles silently and the value
/// becomes nil on the next write. It cost AKAs once, the whole career span
/// later, and enrichment state plus links after that.
///
/// The tests below pin the two things that make it recur — a fully-populated
/// profile must survive a rename, and the field COUNT must not grow without
/// somebody looking at these tests.
final class EntityProfilePreservationTests: XCTestCase {

    /// Every field set to a distinctive non-default value, so a dropped field
    /// shows up as a nil rather than as a coincidental match.
    private func fullyPopulated(id: String = "actor:Original Name") -> EntityProfile {
        EntityProfile(
            id: id,
            bio: "A biography.",
            photoUrl: "photo.jpg",
            homePage: "https://example.com",
            gender: "Female",
            hairColor: "Brown",
            birthYear: 1990,
            countryOfOrigin: "US",
            rating: 4,
            tags: ["tag-one", "tag-two"],
            galleryUrls: ["a.jpg", "b.jpg"],
            akas: ["Alias One", "Alias Two"],
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            birthDate: "1990-04-12",
            careerSpanRaw: "2010–2018",
            careerStartYear: 2010,
            careerEndYear: 2018,
            ageAtCareerStart: 20,
            enrichmentState: .matched,
            enrichmentSource: "TestSource",
            enrichmentCheckedAt: Date(timeIntervalSince1970: 1_700_000_000),
            links: [EntityLink(url: "https://example.com/profile", label: "Example")]
        )
    }

    // MARK: - The structural guard

    /// Fails when a stored property is added to `EntityProfile`.
    ///
    /// This is the test that actually prevents the recurrence: it cannot tell
    /// you WHERE the new field was forgotten, but it forces a person to come
    /// and look at the copy sites listed below before the change can land.
    func testFieldCountIsPinned() {
        let count = Mirror(reflecting: fullyPopulated()).children.count
        XCTAssertEqual(count, 22, """
            EntityProfile gained or lost a stored property (now \(count)).

            A new field must be carried by EVERY path that rebuilds a profile.
            Check each of these, then update this expected count:

              • EntityProfile.renamed(to:)          — rename / canonical rename
              • LibraryStore.renameEntity           — the merge-into-existing branch
              • ActorSync.convergedExport           — plus ActorSyncField if it conflicts
              • ActorLibraryPackage.applyActorMerge — move between libraries
              • ActorCSV.profile(from:) / .row(from:) — export and re-import
              • EnrichmentReview.merged             — accepting a lookup
              • MergeSemantics.merged               — overlay of two libraries
              • EntityProfileEditorView             — editedProfile, save, applyEnrichment
            """)
    }

    // MARK: - Rename

    func testRenamePreservesEveryField() {
        let original = fullyPopulated()
        let renamed = original.renamed(to: "actor:New Name")

        XCTAssertEqual(renamed.id, "actor:New Name")

        // Compared field-by-field rather than with `==` so a failure names the
        // field that was dropped instead of just saying the structs differ.
        XCTAssertEqual(renamed.bio, original.bio)
        XCTAssertEqual(renamed.photoUrl, original.photoUrl)
        XCTAssertEqual(renamed.homePage, original.homePage)
        XCTAssertEqual(renamed.gender, original.gender)
        XCTAssertEqual(renamed.hairColor, original.hairColor)
        XCTAssertEqual(renamed.birthYear, original.birthYear)
        XCTAssertEqual(renamed.countryOfOrigin, original.countryOfOrigin)
        XCTAssertEqual(renamed.rating, original.rating)
        XCTAssertEqual(renamed.tags, original.tags)
        XCTAssertEqual(renamed.galleryUrls, original.galleryUrls)
        XCTAssertEqual(renamed.akas, original.akas)
        XCTAssertEqual(renamed.createdAt, original.createdAt)
        XCTAssertEqual(renamed.birthDate, original.birthDate)
        XCTAssertEqual(renamed.careerSpanRaw, original.careerSpanRaw)
        XCTAssertEqual(renamed.careerStartYear, original.careerStartYear)
        XCTAssertEqual(renamed.careerEndYear, original.careerEndYear)
        XCTAssertEqual(renamed.ageAtCareerStart, original.ageAtCareerStart)
        XCTAssertEqual(renamed.enrichmentState, original.enrichmentState)
        XCTAssertEqual(renamed.enrichmentSource, original.enrichmentSource)
        XCTAssertEqual(renamed.enrichmentCheckedAt, original.enrichmentCheckedAt)
        XCTAssertEqual(renamed.links, original.links)
    }

    /// A rename must not quietly become a way of losing enrichment — the case
    /// that matters most, because accepting a canonical name from a lookup
    /// renames the actor immediately after enriching them.
    func testRenameKeepsEnrichmentAndLinks() {
        let renamed = fullyPopulated().renamed(to: "actor:Canonical")
        XCTAssertEqual(renamed.enrichmentState, .matched)
        XCTAssertEqual(renamed.careerStartYear, 2010)
        XCTAssertEqual(renamed.links.count, 1)
        XCTAssertEqual(renamed.links.first?.label, "Example")
    }

    // MARK: - Sync convergence

    /// Sync used to carry v17 and v18 but not links or the check timestamp, so
    /// syncing two libraries dropped links that only one of them held.
    func testConvergedExportUnionsLinksAndKeepsLatestCheck() throws {
        let early = Date(timeIntervalSince1970: 1_600_000_000)
        let late = Date(timeIntervalSince1970: 1_700_000_000)

        var a = EntityProfile(id: "actor:Shared")
        a.links = [EntityLink(url: "https://one.example", label: "One")]
        a.enrichmentCheckedAt = early

        var b = EntityProfile(id: "actor:Shared")
        b.links = [EntityLink(url: "https://two.example", label: "Two")]
        b.enrichmentCheckedAt = late

        let export = ActorSync.convergedExport(
            actorIds: ["actor:Shared"],
            resolutions: [:],
            snapshots: [
                ActorSync.LibrarySnapshot(url: URL(fileURLWithPath: "/tmp/a"),
                                export: ActorLibraryExport(formatVersion: 1, exportedAt: early,
                                                           profiles: [a], photos: [])),
                ActorSync.LibrarySnapshot(url: URL(fileURLWithPath: "/tmp/b"),
                                export: ActorLibraryExport(formatVersion: 1, exportedAt: late,
                                                           profiles: [b], photos: []))
            ])

        let converged = try XCTUnwrap(export.profiles.first)
        XCTAssertEqual(converged.links.count, 2, "links from both libraries should survive")
    }

    /// A converged profile must never carry a check timestamp without the
    /// enrichment result that timestamp belongs to.
    ///
    /// `MergeSemantics.newerChecked` hands the whole enrichment triple to
    /// whichever side has the newer timestamp. A converged profile with the
    /// newest timestamp and a nil state therefore WIPES a populated result in
    /// every destination — and because the wipe recreates the gap the plan was
    /// reporting, the same actors are offered for sync forever and never
    /// converge. This is the regression that stranded 15 actors.
    func testConvergedNeverCarriesATimestampWithoutAResult() throws {
        let checked = Date(timeIntervalSince1970: 1_700_000_000)

        // Two libraries disagreeing on the result: an unresolved conflict
        // resolves to .skip, which encodes the state as nil.
        var a = EntityProfile(id: "actor:Disputed")
        a.enrichmentState = .matched
        a.enrichmentCheckedAt = checked

        var b = EntityProfile(id: "actor:Disputed")
        b.enrichmentState = .noMatch
        b.enrichmentCheckedAt = Date(timeIntervalSince1970: 1_600_000_000)

        let export = ActorSync.convergedExport(
            actorIds: ["actor:Disputed"],
            resolutions: [:],   // unresolved ⇒ skip ⇒ state nil
            snapshots: [
                ActorSync.LibrarySnapshot(url: URL(fileURLWithPath: "/tmp/a"),
                                          export: ActorLibraryExport(formatVersion: 1, exportedAt: checked,
                                                                     profiles: [a], photos: [])),
                ActorSync.LibrarySnapshot(url: URL(fileURLWithPath: "/tmp/b"),
                                          export: ActorLibraryExport(formatVersion: 1, exportedAt: checked,
                                                                     profiles: [b], photos: []))
            ])

        let converged = try XCTUnwrap(export.profiles.first)
        XCTAssertNil(converged.enrichmentState, "an unresolved conflict skips the state")
        XCTAssertNil(converged.enrichmentCheckedAt,
                     "no result means no timestamp — otherwise the merge erases the destination's result")
    }

    /// The agreeing case still carries the timestamp, so syncing a result also
    /// syncs when it was established.
    func testConvergedKeepsTheTimestampThatProducedTheAgreedResult() throws {
        let older = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)

        var a = EntityProfile(id: "actor:Agreed")
        a.enrichmentState = .matched
        a.enrichmentCheckedAt = older

        var b = EntityProfile(id: "actor:Agreed")
        b.enrichmentState = .matched
        b.enrichmentCheckedAt = newer

        let export = ActorSync.convergedExport(
            actorIds: ["actor:Agreed"],
            resolutions: [:],
            snapshots: [
                ActorSync.LibrarySnapshot(url: URL(fileURLWithPath: "/tmp/a"),
                                          export: ActorLibraryExport(formatVersion: 1, exportedAt: older,
                                                                     profiles: [a], photos: [])),
                ActorSync.LibrarySnapshot(url: URL(fileURLWithPath: "/tmp/b"),
                                          export: ActorLibraryExport(formatVersion: 1, exportedAt: newer,
                                                                     profiles: [b], photos: []))
            ])

        let converged = try XCTUnwrap(export.profiles.first)
        XCTAssertEqual(converged.enrichmentState, .matched)
        XCTAssertEqual(converged.enrichmentCheckedAt, newer)
    }

    /// Stored data can hold the same URL twice; merging must not trap.
    func testMergedToleratesDuplicateURLsInStoredData() {
        let dupes = [EntityLink(url: "https://a.example", label: "First"),
                     EntityLink(url: "https://a.example", label: "Second")]
        let out = EntityLink.merged(dupes, adding: [EntityLink(url: "https://b.example")])
        XCTAssertEqual(out.filter { $0.url == "https://a.example" }.count, 2,
                       "existing entries are preserved as-is")
        XCTAssertTrue(out.contains { $0.url == "https://b.example" })
    }
}
