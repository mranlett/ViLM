// SidecarImportTests.swift
// Metadata Sidecars S1 — reading a document this app did not write (#74).
//
// ⚠️ All names invented. This repository is public.

import XCTest
@testable import LibraryCore

final class SidecarImportTests: XCTestCase {

    private func blank(_ path: String = "new.mp4") -> Asset {
        Asset(relativePath: path, fileName: (path as NSString).lastPathComponent)
    }

    private let document = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <movie>
      <title>Late Checkout</title>
      <set>
        <name>Harbour Nights</name>
      </set>
      <premiered>2019-04-12</premiered>
      <year>2019</year>
      <plot>A description.</plot>
      <userrating>8</userrating>
      <studio>Example Pictures</studio>
      <tag>Outdoors</tag>
      <actor>
        <name>Alice Example</name>
        <order>0</order>
      </actor>
      <actor>
        <name>Bob Example</name>
        <order>1</order>
      </actor>
      <uniqueid type="Example Source">abc-123</uniqueid>
    </movie>
    """

    // MARK: - Reading

    func testTheDocumentIsReadInFull() {
        let c = SidecarReader.read(document)!
        XCTAssertEqual(c.title, "Late Checkout")
        XCTAssertEqual(c.series, "Harbour Nights")
        XCTAssertEqual(c.premiered, "2019-04-12")
        XCTAssertEqual(c.plot, "A description.")
        XCTAssertEqual(c.userRating, 8)
        XCTAssertEqual(c.studio, "Example Pictures")
        XCTAssertEqual(c.tags, ["Outdoors"])
        XCTAssertEqual(c.actors, ["Alice Example", "Bob Example"])
        XCTAssertEqual(c.uniqueId, SidecarUniqueId(type: "Example Source", value: "abc-123"))
    }

    /// ⚠️ `name` appears inside BOTH `actor` and `set`. Without knowing which
    /// parent it sits under, a series becomes a cast member or vice versa —
    /// and the document we write ourselves contains both.
    func testANameInsideASetIsASeriesNotACastMember() {
        let c = SidecarReader.read(document)!
        XCTAssertFalse(c.actors.contains("Harbour Nights"))
        XCTAssertEqual(c.series, "Harbour Nights")
    }

    /// ⭐ Round-trips against our own writer, so the two cannot drift.
    func testWhatTheWriterEmitsIsWhatTheReaderReads() {
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                          tags: ["tag:Outdoors"], sourceDescription: "A description.",
                          rating: 4, videoName: "Harbour Nights", episode: "Late Checkout",
                          contentKind: .scene, releaseDate: "2019-04-12")
        let written = MetadataSidecar.document(
            for: asset,
            cast: [SidecarPerformer(name: "Alice Example", thumbURL: nil)],
            studio: "Example Pictures", fallbackTitle: "a")!

        let read = SidecarReader.read(written)!
        XCTAssertEqual(read.title, "Late Checkout")
        XCTAssertEqual(read.series, "Harbour Nights")
        XCTAssertEqual(read.studio, "Example Pictures")
        XCTAssertEqual(read.actors, ["Alice Example"])
        XCTAssertEqual(SidecarImport.vilmRating(from: read.userRating), 4,
                       "the rating survives the trip through Kodi's scale")
    }

    // MARK: - 🚨 S1c — malformed imports NOTHING, not half

    func testS1cAMalformedDocumentImportsNothing() {
        let truncated = """
        <movie>
          <title>Late Checkout</title>
          <plot>A description.
        """
        XCTAssertNil(SidecarReader.read(truncated),
                     "a document that failed partway must not contribute the part that parsed")
    }

    /// Well-formed XML that is not a sidecar parses perfectly and means nothing.
    func testSomebodyElsesXmlUnderAnNfoNameIsNotASidecar() {
        XCTAssertNil(SidecarReader.read("<config><title>Late Checkout</title></config>"))
    }

    func testAnEmptyDocumentIsNotContents() {
        XCTAssertNil(SidecarReader.read("<movie></movie>"))
    }

    // MARK: - 🚨 S1d — only the document named for THIS video is ever read

    /// The defence is that nothing else is ever looked at. A `.nfo` belonging
    /// to another video cannot be reached from here even when it sits in the
    /// same folder — a property of never looking rather than of detecting.
    func testS1dASidecarForAnotherVideoIsNotReadForThisOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("S1d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try document.write(to: dir.appendingPathComponent("Other Video.nfo"),
                           atomically: true, encoding: .utf8)

        XCTAssertNil(SidecarReader.read(besideVideo: "This Video.mp4", in: dir))
        XCTAssertNotNil(SidecarReader.read(besideVideo: "Other Video.mp4", in: dir),
                        "and the one that IS named for its video is read")
    }

    // MARK: - S1a — no record, so the sidecar is the only data

    func testS1aAFileWithNoRecordImportsTheSidecarsValues() {
        let contents = SidecarReader.read(document)!
        guard case let .accepted(asset) = SidecarImport.decide(contents, existing: nil,
                                                               importingInto: blank())
        else { return XCTFail("expected acceptance") }

        XCTAssertEqual(asset.episode, "Late Checkout")
        XCTAssertEqual(asset.videoName, "Harbour Nights")
        XCTAssertEqual(asset.sourceDescription, "A description.")
        XCTAssertEqual(asset.releaseDate, "2019-04-12")
        XCTAssertEqual(asset.rating, 4)
        XCTAssertEqual(asset.actors, ["Alice Example", "Bob Example"])
        XCTAssertEqual(asset.studios, ["Example Pictures"])
        XCTAssertTrue(asset.tags.contains("tag:Outdoors"))
    }

    /// 🚨 Declaration is a human act (N4). A guessed `personal` is a privacy
    /// failure, and any other guess silently opts a video into being filed and
    /// into having its metadata sent to a provider.
    func testImportingASidecarNeverDeclaresAContentKind() {
        let contents = SidecarReader.read(document)!
        guard case let .accepted(asset) = SidecarImport.decide(contents, existing: nil,
                                                               importingInto: blank())
        else { return XCTFail("expected acceptance") }
        XCTAssertNil(asset.contentKind, "an imported video stays undeclared")
    }

    /// 🚨 Identity is not accepted, only description. A `uniqueid` from a file
    /// that may have been copied from an unrelated video would attach this one
    /// to someone else's source record, and every later refresh would compound
    /// it against the wrong upstream.
    func testTheSourceRecordIdIsNeverAccepted() {
        let contents = SidecarReader.read(document)!
        XCTAssertNotNil(contents.uniqueId, "it is read…")
        guard case let .accepted(asset) = SidecarImport.decide(contents, existing: nil,
                                                               importingInto: blank())
        else { return XCTFail("expected acceptance") }
        XCTAssertNil(asset.enrichmentSourceId, "…and it is not applied")
        XCTAssertNil(asset.enrichmentSource)
    }

    // MARK: - 🚨 S1b — a record exists, so the database wins

    func testS1bAnExistingRecordIgnoresTheSidecarAndReportsTheDifference() {
        let existing = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                             sourceDescription: "The catalogue's own blurb.",
                             episode: "A Different Title")
        let contents = SidecarReader.read(document)!

        guard case let .reported(differences) = SidecarImport.decide(
            contents, existing: existing, importingInto: blank())
        else { return XCTFail("expected a report, never an overwrite") }

        let title = differences.first { $0.field == "Title" }
        XCTAssertEqual(title?.database, "A Different Title")
        XCTAssertEqual(title?.sidecar, "Late Checkout")
        XCTAssertTrue(differences.contains { $0.field == "Description" })
    }

    /// ⭐ Silence is not a claim. A field the document omits must not be
    /// reported as a disagreement, or the handful that genuinely conflict are
    /// buried under every field the other tool did not bother to write.
    func testAnOmittedFieldIsNotADifference() {
        let existing = Asset(relativePath: "a.mp4", fileName: "a.mp4",
                             sourceDescription: "Kept.", episode: "Late Checkout")
        let sparse = SidecarReader.read("<movie><title>Late Checkout</title></movie>")!

        let differences = SidecarImport.differences(sparse, against: existing)
        XCTAssertTrue(differences.isEmpty,
                      "the title agrees and nothing else was claimed")
    }

    // MARK: - The rating scale

    func testTheKodiScaleMapsBackWithoutInventingAZero() {
        XCTAssertNil(SidecarImport.vilmRating(from: 0), "Kodi's 0 is unrated, not a rating")
        XCTAssertNil(SidecarImport.vilmRating(from: nil))
        XCTAssertEqual(SidecarImport.vilmRating(from: 1), 1)
        XCTAssertEqual(SidecarImport.vilmRating(from: 8), 4)
        XCTAssertEqual(SidecarImport.vilmRating(from: 9), 5)
        XCTAssertEqual(SidecarImport.vilmRating(from: 10), 5)
    }

    /// Every ViLM rating survives the round trip the writer performs.
    func testEveryRatingRoundTripsThroughTheWritersDoubling() {
        for rating in 1...5 {
            XCTAssertEqual(SidecarImport.vilmRating(from: rating * 2), rating)
        }
    }

    // MARK: - Through the scanner, which is where the rule actually applies

    /// ⭐ End to end, on a real directory. The unit tests above pin the rules;
    /// this pins that the scanner is the thing applying them, which is the part
    /// a green suite said nothing about while the reader sat unused.
    func testScanningImportsASidecarOnceAndThenLeavesTheRecordAlone() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
            try? FileManager.default.removeItem(at: dir)
        }

        try Data().write(to: dir.appendingPathComponent("Late Checkout.mp4"))
        try document.write(to: dir.appendingPathComponent("Late Checkout.nfo"),
                           atomically: true, encoding: .utf8)

        let store = try LibraryStore(at: dir)
        let first = try await LibraryScanner(store: store).scan(at: dir)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(first.importedFromSidecar, 1)
        let imported = try XCTUnwrap(try store.fetchAllAssets().first)
        XCTAssertEqual(imported.episode, "Late Checkout")
        XCTAssertEqual(imported.studios, ["Example Pictures"])
        XCTAssertNil(imported.contentKind, "still undeclared")

        // 🚨 The second scan must not consult the document at all. Editing the
        // record and re-scanning is exactly how an operator would discover
        // that a sidecar had quietly become authoritative.
        var edited = imported
        edited.episode = "The Operator's Own Title"
        try store.updateAsset(edited)

        let second = try await LibraryScanner(store: store).scan(at: dir)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.importedFromSidecar, 0, "a known file's sidecar is not read")
        XCTAssertEqual(try store.fetchAllAssets().first?.episode, "The Operator's Own Title",
                       "the database wins")
    }
}
