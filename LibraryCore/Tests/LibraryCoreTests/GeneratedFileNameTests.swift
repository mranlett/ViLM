// GeneratedFileNameTests.swift
// The per-video rename proposal — the same rules as the plan, not the old ones.
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class GeneratedFileNameTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenName-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    /// ⚠️ A MATCHED studio profile, because N1 says a `Studio/` folder comes
    /// from the verified studio lexicon — a studio still being worked on leaves
    /// the video unprocessed, and the name drops the segment. The first version
    /// of these tests used bare tag strings and asserted a studio-led name that
    /// the rules correctly refused to produce.
    private func studioProfile(_ name: String) {
        var p = EntityProfile(id: "studio:\(name)")
        p.enrichmentState = .matched
        try? store.saveEntityProfile(p)
    }

    private func actorProfile(_ name: String) {
        var p = EntityProfile(id: "actor:\(name)")
        p.enrichmentState = .matched
        try? store.saveEntityProfile(p)
    }

    @discardableResult
    private func video(_ name: String, tags: [String] = [], kind: ContentKind? = .scene,
                       episode: String? = "Late Checkout",
                       released: String? = "2019-04-12") -> Asset {
        let asset = Asset(relativePath: name, fileName: name, tags: tags,
                          episode: episode, contentKind: kind, releaseDate: released)
        try? store.insertAsset(asset)
        return asset
    }

    /// 🚨 The defect this exists for: the per-video Rename proposed a name from
    /// the OLD grammar — `Actors - Series - Tags - Studios`, studio last, tags
    /// in the middle — so the one screen reached for a single file undid the
    /// naming rules one video at a time.
    func testTheProposalUsesTheCurrentGrammarNotTheOldOne() throws {
        studioProfile("Example Pictures"); actorProfile("Alice Example")
        let asset = video("junk name here.mp4",
                          tags: ["actor:Alice Example", "studio:Example Pictures",
                                 "tag:Outdoors"])

        let outcome = try XCTUnwrap(try store.generatedFileName(for: asset.id))
        guard case let .path(name) = outcome else { return XCTFail("expected a name") }

        XCTAssertTrue(name.hasPrefix("Example Pictures - "),
                      "the studio leads the scene grammar; it used to trail")
        XCTAssertFalse(name.contains("Outdoors"),
                       "D2 removed tags from filenames — re-tagging must not rename a file")
        XCTAssertTrue(name.contains("Alice Example"))
        XCTAssertTrue(name.contains("Late Checkout"))
        XCTAssertTrue(name.hasSuffix(".mp4"))
    }

    /// ⭐ A FILE NAME, not a path. The dialog renames where the file sits;
    /// filing it into its studio folder is the plan's job, and returning a path
    /// here would have produced a filename containing a slash.
    func testItReturnsAFileNameAndNotAPath() throws {
        studioProfile("Example Pictures")
        let asset = video("a.mp4", tags: ["studio:Example Pictures"])
        let outcome = try XCTUnwrap(try store.generatedFileName(for: asset.id))
        guard case let .path(name) = outcome else { return XCTFail("expected a name") }
        XCTAssertFalse(name.contains("/"))
    }

    /// 🚨 A video the rules refuse to file gets NO proposal, and says why. The
    /// old generator always produced something, so an undeclared video still
    /// received a confident suggestion built to a superseded scheme.
    func testAnUndeclaredVideoIsRefusedWithAReason() throws {
        let asset = video("a.mp4", tags: ["actor:Alice Example"], kind: nil)

        let outcome = try XCTUnwrap(try store.generatedFileName(for: asset.id))
        guard case let .skipped(skip) = outcome else {
            return XCTFail("undeclared content must be refused, not named")
        }
        XCTAssertEqual(skip, .undeclared)
        XCTAssertFalse(skip.reason.isEmpty)
    }

    /// nil means "already correct" — distinct from a refusal, and the dialog
    /// shows the current name rather than an empty field or a warning.
    func testAVideoAlreadyCorrectlyNamedProposesNothing() throws {
        studioProfile("Example Pictures"); actorProfile("Alice Example")
        let asset = video("a.mp4", tags: ["studio:Example Pictures", "actor:Alice Example"])
        let first = try XCTUnwrap(try store.generatedFileName(for: asset.id))
        guard case let .path(name) = first else { return XCTFail("expected a name") }

        // Put the file where the plan wants it, under the generated name.
        var moved = asset
        moved.fileName = name
        moved.relativePath = "Example Pictures/\(name)"
        try store.updateAsset(moved)

        XCTAssertNil(try store.generatedFileName(for: asset.id),
                     "already in place is neither a rename nor a refusal")
    }

    /// ⚠️ Pins the CONTRAST with the superseded generator, so the day someone
    /// re-points this at the old property the test says what was lost. A test
    /// of the new name alone would pass on code that quietly kept both.
    func testTheOldGeneratorAndTheNewOneDisagreeAndTheNewOneWins() throws {
        studioProfile("Example Pictures"); actorProfile("Alice Example")
        let asset = video("a.mp4", tags: ["actor:Alice Example",
                                          "studio:Example Pictures", "tag:Outdoors"])
        let outcome = try XCTUnwrap(try store.generatedFileName(for: asset.id))
        guard case let .path(current) = outcome else { return XCTFail("expected a name") }

        let superseded = try XCTUnwrap(asset.suggestedFileNameFromTags)
        XCTAssertNotEqual(current, superseded)
        XCTAssertTrue(superseded.contains("Outdoors"), "the old one carried tags…")
        XCTAssertFalse(current.contains("Outdoors"), "…and the current one does not")
    }
}
