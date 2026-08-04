// EntityLinkTests.swift
//
// Schema v19. Generalises the single `homePage` into a labelled list, so an
// entity can carry references to several systems.
//
// The type is deliberately generic — a label and a URL. Values like "IMDb" are
// supplied at runtime by the operator or a provider; core never names one.

import XCTest
@testable import LibraryCore

final class EntityLinkTests: XCTestCase {

    // MARK: - Validation

    func testOnlyWebLinksAreValid() {
        // A file: or javascript: value from a provider must never become
        // something the app renders as tappable.
        XCTAssertTrue(EntityLink(url: "https://example.org/a").isValid)
        XCTAssertTrue(EntityLink(url: "http://example.org").isValid)
        XCTAssertFalse(EntityLink(url: "file:///etc/passwd").isValid)
        XCTAssertFalse(EntityLink(url: "javascript:alert(1)").isValid)
        XCTAssertFalse(EntityLink(url: "not a url").isValid)
        XCTAssertFalse(EntityLink(url: "https://").isValid)
    }

    // MARK: - Display

    func testAnUnlabelledLinkFallsBackToItsHost() {
        // A bare URL renders poorly; the host is the next best thing.
        XCTAssertEqual(EntityLink(url: "https://www.example.org/x").displayLabel, "example.org")
        XCTAssertEqual(EntityLink(url: "https://example.org/x").displayLabel, "example.org")
    }

    func testASuppliedLabelWins() {
        XCTAssertEqual(EntityLink(url: "https://example.org", label: "Somewhere").displayLabel,
                       "Somewhere")
    }

    // MARK: - Merging

    func testMergingIsAUnionKeyedOnURL() {
        // Union, like tags and AKAs: enrichment may add a link but must never
        // remove one the operator curated.
        let existing = [EntityLink(url: "https://a.test", label: "A")]
        let merged = EntityLink.merged(existing, adding: [EntityLink(url: "https://b.test", label: "B")])
        XCTAssertEqual(merged.map(\.url), ["https://a.test", "https://b.test"])
    }

    func testTheSameURLTwiceIsOneLink() {
        let merged = EntityLink.merged([EntityLink(url: "https://a.test", label: "A")],
                                       adding: [EntityLink(url: "https://a.test", label: "Other")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].label, "A", "an existing label is not overwritten")
    }

    func testAnIncomingLabelFillsABlankOne() {
        // The operator pasted a URL; a provider later supplies what it is.
        let merged = EntityLink.merged([EntityLink(url: "https://a.test")],
                                       adding: [EntityLink(url: "https://a.test", label: "Named")])
        XCTAssertEqual(merged[0].label, "Named")
    }

    func testInvalidIncomingLinksAreDropped() {
        let merged = EntityLink.merged([], adding: [
            EntityLink(url: "https://ok.test", label: "OK"),
            EntityLink(url: "javascript:alert(1)", label: "Bad"),
        ])
        XCTAssertEqual(merged.map(\.url), ["https://ok.test"])
    }

    func testOrderIsPreserved() {
        // A list that reshuffles on every merge looks like data loss.
        let existing = (0..<3).map { EntityLink(url: "https://\($0).test") }
        let merged = EntityLink.merged(existing, adding: [EntityLink(url: "https://new.test")])
        XCTAssertEqual(merged.map(\.url).prefix(3).map { $0 }, existing.map(\.url))
    }

    // MARK: - Persistence

    func testLinksRoundTripThroughCoding() {
        let profile = EntityProfile(id: "actor:A",
                                    links: [EntityLink(url: "https://a.test", label: "A")])
        let data = try! JSONEncoder().encode(profile)
        let back = try! JSONDecoder().decode(EntityProfile.self, from: data)
        XCTAssertEqual(back.links, profile.links)
    }

    func testAProfilePredatingV19DecodesWithNoLinks() {
        let json = #"{"id":"actor:A","tags":[],"gallery_urls":[],"akas":[]}"#
        let decoded = try? JSONDecoder().decode(EntityProfile.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.links, [])
    }

    // MARK: - The four reconstruction sites

    func testLinksSurviveTheFederatedMerge() {
        let higher = EntityProfile(id: "actor:A", links: [EntityLink(url: "https://h.test")])
        let lower  = EntityProfile(id: "actor:A", links: [EntityLink(url: "https://l.test")])
        XCTAssertEqual(MergeSemantics.mergedProfileView(higher: higher, lower: lower).links.count, 2)
    }

    func testEnrichmentUnionsRatherThanReplaces() {
        var proposal = ActorMetadataProposal()
        proposal.externalLinks = .init([EntityLink(url: "https://new.test", label: "New")])
        let existing = EntityProfile(id: "actor:A",
                                     links: [EntityLink(url: "https://mine.test", label: "Mine")])
        let applied = ActorEnrichment.apply(proposal, to: existing, entityId: "actor:A",
                                           accepting: [ActorEnrichment.Field.links])
        XCTAssertEqual(applied.links.map(\.label), ["Mine", "New"])
    }

    func testDecliningTheProposalLeavesLinksAlone() {
        var proposal = ActorMetadataProposal()
        proposal.externalLinks = .init([EntityLink(url: "https://new.test")])
        let existing = EntityProfile(id: "actor:A", links: [EntityLink(url: "https://mine.test")])
        let applied = ActorEnrichment.apply(proposal, to: existing, entityId: "actor:A",
                                           accepting: [])
        XCTAssertEqual(applied.links.map(\.url), ["https://mine.test"])
    }

    func testTheTypeNamesNoSystem() {
        // Core schema in a public repository. The SHAPE is a label and a URL;
        // every concrete system name is runtime data.
        let encoded = try! JSONEncoder().encode(EntityLink(url: "https://a.test", label: "X"))
        let keys = Set((try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]).keys)
        XCTAssertEqual(keys, ["url", "label"])
    }
}
