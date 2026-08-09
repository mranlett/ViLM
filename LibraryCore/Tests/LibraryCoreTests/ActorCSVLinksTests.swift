// ActorCSVLinksTests.swift
// The Links column (issue #29).
//
// ⚠️ The tests that matter most are the destructive ones — L6, L7 and L8. The
// CSV is a HAND-EDITED import path, and every previous defect in this format
// was a blank or missing cell being read as "remove it" rather than "said
// nothing". Links are the field where that would hurt most: 1,008 of 1,013
// identified actors carry them, and nothing regenerates them without re-fetch.

import XCTest
@testable import LibraryCore

final class ActorCSVLinksTests: XCTestCase {

    private let identity: (String) -> String = { $0 }

    private func existing(_ links: [EntityLink]) -> EntityProfile {
        EntityProfile(id: "actor:Jane Doe", links: links)
    }

    /// A full-width row with a Links cell.
    private func row(links: String, name: String = "Jane Doe") -> [String] {
        var cols = Array(repeating: "", count: 23)
        cols[0] = name
        cols[22] = links
        return cols
    }

    // MARK: - Round trip

    // L1 — a labelled link survives out and back.
    func testALabelledLinkRoundTrips() {
        let links = [EntityLink(url: "https://example.com/x", label: "Example")]
        let cell = ActorCSV.joinLinks(links)
        XCTAssertEqual(cell, "Example>https://example.com/x")
        XCTAssertEqual(ActorCSV.splitLinks(cell), links)
    }

    // L2 — an unlabelled link writes as the bare URL, which is what someone
    // hand-editing would paste in.
    func testAnUnlabelledLinkIsWrittenAsABareURL() {
        let cell = ActorCSV.joinLinks([EntityLink(url: "https://example.com/x")])
        XCTAssertEqual(cell, "https://example.com/x")
        XCTAssertEqual(ActorCSV.splitLinks(cell),
                       [EntityLink(url: "https://example.com/x")])
    }

    // L3 — several links share one cell, pipe-separated like AKAs and Tags.
    func testSeveralLinksShareOneCell() {
        let links = [EntityLink(url: "https://a.example.com", label: "A"),
                     EntityLink(url: "https://b.example.com")]
        XCTAssertEqual(ActorCSV.splitLinks(ActorCSV.joinLinks(links)), links)
    }

    // L4 — ⭐ a URL containing a query string round-trips. This is why the
    // label separator is `>` and not `=`.
    func testAURLWithAQueryStringIsNotSplitOnItsEquals() {
        let link = EntityLink(url: "https://example.com/s?q=1&r=2", label: "Search")
        XCTAssertEqual(ActorCSV.splitLinks(ActorCSV.joinLinks([link])), [link])
    }

    // L5 — ⚠️ a stray separator degrades to "link with no label" rather than
    // truncating the address. A truncated URL looks plausible and is dead.
    func testAStraySeparatorDoesNotTruncateTheURL() {
        let parsed = ActorCSV.splitLinks("not a url>also not a url")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.url, "not a url>also not a url")
        XCTAssertTrue(parsed.first?.label.isEmpty == true)
    }

    // MARK: - 🚨 The destructive cases

    // L6 — a row from a file written BEFORE this column existed has no cell 22
    // at all, and must leave stored links alone.
    func testAnOlderNarrowRowDoesNotClearStoredLinks() {
        let held = [EntityLink(url: "https://example.com/held", label: "Held")]
        var cols = Array(repeating: "", count: 22)      // pre-Links width
        cols[0] = "Jane Doe"
        let merged = ActorCSV.merge(columns: cols, existing: existing(held),
                                    decorateCountry: identity)
        XCTAssertEqual(merged?.links, held)
    }

    // L7 — a BLANK cell means "said nothing", not "remove them all". Someone
    // clearing a column in a spreadsheet must not wipe curated references.
    func testABlankLinksCellDoesNotClearStoredLinks() {
        let held = [EntityLink(url: "https://example.com/held", label: "Held")]
        let merged = ActorCSV.merge(columns: row(links: ""), existing: existing(held),
                                    decorateCountry: identity)
        XCTAssertEqual(merged?.links, held)
    }

    // L8 — incoming links UNION with stored ones; an import never removes.
    // Removal stays an in-app action, exactly as it does for tags and AKAs.
    func testIncomingLinksUnionRatherThanReplace() {
        let held = [EntityLink(url: "https://example.com/held", label: "Held")]
        let merged = ActorCSV.merge(columns: row(links: "New>https://example.com/new"),
                                    existing: existing(held), decorateCountry: identity)
        XCTAssertEqual(merged?.links.map(\.url),
                       ["https://example.com/held", "https://example.com/new"])
    }

    // MARK: - 🚨 Untrusted input

    // L9 — a non-http(s) URL typed into a CSV never lands. The app renders
    // links as tappable, so this is the guard that matters.
    func testANonHttpURLFromACSVIsRefused() {
        let merged = ActorCSV.merge(
            columns: row(links: "Evil>javascript:alert(1)"),
            existing: existing([]), decorateCountry: identity)
        XCTAssertEqual(merged?.links, [], "only http(s) may reach a tappable link")

        let fileURL = ActorCSV.merge(
            columns: row(links: "file:///etc/passwd"),
            existing: existing([]), decorateCountry: identity)
        XCTAssertEqual(fileURL?.links, [])
    }

    // L10 — a rubbish cell yields no links and does not throw or corrupt the row.
    func testARubbishCellYieldsNoLinksAndDoesNotBreakTheRow() {
        let merged = ActorCSV.merge(columns: row(links: "|||"),
                                    existing: existing([]), decorateCountry: identity)
        XCTAssertNotNil(merged)
        XCTAssertEqual(merged?.links, [])
    }

    // MARK: - Export

    // L11 — the exported row actually carries the links, which is the whole
    // point of the issue. 1,008 of 1,013 actors had them and the file did not.
    func testAnExportedRowCarriesTheLinks() {
        let profile = EntityProfile(
            id: "actor:Jane Doe",
            links: [EntityLink(url: "https://example.com/x", label: "Example")])
        let line = ActorCSV.row(name: "Jane Doe", profile: profile,
                                stripCountry: identity)
        XCTAssertTrue(line.contains("Example>https://example.com/x"),
                      "links must appear in the exported row")
    }

    // L12 — a no-edit round trip through export and merge is stable.
    func testANoEditRoundTripIsStable() {
        let links = [EntityLink(url: "https://a.example.com", label: "A"),
                     EntityLink(url: "https://b.example.com")]
        let profile = EntityProfile(id: "actor:Jane Doe", links: links)
        let line = ActorCSV.row(name: "Jane Doe", profile: profile, stripCountry: identity)
        guard let columns = ActorCSV.parse(line).first else {
            return XCTFail("exported row did not parse")
        }
        let merged = ActorCSV.merge(columns: columns, existing: profile,
                                    decorateCountry: identity)
        XCTAssertEqual(merged?.links, links)
    }
}
