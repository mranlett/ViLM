// NodeIdentityTests.swift
// Phase 0 of v28: identity between libraries is the name triple, never a uid.
//
// The assertions that matter most are the two no-op ones — T5 and T6. Phase 0
// is only safe to ship ahead of the re-keying because it changes nothing
// today, and "changes nothing" is a claim that has to be asserted rather than
// asserted-about.

import XCTest
@testable import LibraryCore

final class NodeIdentityTests: XCTestCase {

    // T1 — the legacy form round-trips.
    func testAnIdParsesAndRendersBackUnchanged() {
        let id = "actor:Marta Venlowe"
        let identity = NodeIdentity.parse(id)
        XCTAssertEqual(identity?.type, "actor")
        XCTAssertEqual(identity?.displayName, "Marta Venlowe")
        XCTAssertEqual(identity?.legacyId, id)
    }

    // T2 — 🚨 a name containing a colon survives. Splitting on the last colon,
    // or on every colon, truncates the name and mints a second node for it.
    func testANameContainingAColonIsNotTruncated() {
        let identity = NodeIdentity.parse("studio:Vol 2: The Return")
        XCTAssertEqual(identity?.type, "studio")
        XCTAssertEqual(identity?.displayName, "Vol 2: The Return")
        XCTAssertEqual(identity?.legacyId, "studio:Vol 2: The Return")
    }

    // T3 — a string that is not an id in this scheme is refused, not guessed.
    func testAStringWithNoColonIsNotAnIdentity() {
        XCTAssertNil(NodeIdentity.parse("Marta Venlowe"))
        XCTAssertNil(NodeIdentity.parse(""))
        XCTAssertNil(NodeIdentity.parse(":no type"))
        XCTAssertNil(NodeIdentity.parse("actor:"))
    }

    // T4 — ⚠️ an unrecognised prefix travels intact rather than being dropped.
    // A node from a newer library must survive a round trip through an older
    // build; discarding it would lose data silently on the way back.
    func testAnUnknownTypeIsCarriedRatherThanDiscarded() {
        let identity = NodeIdentity.parse("director:Someone")
        XCTAssertEqual(identity?.type, "director")
        XCTAssertEqual(identity?.legacyId, "director:Someone")
    }

    // T5 — 🚨 THE NO-OP ASSERTION for performers and studios. Today's key is
    // the exact display name, so two spellings that differ only in case must
    // stay DISTINCT. Folding here would merge nodes the current build keeps
    // apart — a behaviour change hidden inside a migration.
    func testPerformerAndStudioResolutionIsExactAndDoesNotFold() {
        let lower = NodeIdentity(type: "actor", displayName: "marta venlowe")
        let upper = NodeIdentity(type: "actor", displayName: "Marta Venlowe")
        XCTAssertNotEqual(lower.resolutionKey, upper.resolutionKey)

        let spaced = NodeIdentity(type: "studio", displayName: "Big Studio")
        let joined = NodeIdentity(type: "studio", displayName: "BigStudio")
        XCTAssertNotEqual(spaced.resolutionKey, joined.resolutionKey)
    }

    // T6 — THE NO-OP ASSERTION for tags, which is the opposite rule. The tag
    // path already resolves by the folded `identityKey`, so matching it is
    // reproducing behaviour rather than inventing it.
    func testTagResolutionFoldsExactlyAsTheTagVocabularyDoes() {
        let a = NodeIdentity(type: "tag", displayName: "SCUBA")
        let b = NodeIdentity(type: "tag", displayName: "Scuba")
        XCTAssertEqual(a.resolutionKey, b.resolutionKey)
        XCTAssertEqual(NodeIdentity(type: "tag", displayName: "Scuba").resolutionKey,
                       "tag\u{1F}\u{1F}\(TagNormalizer.identityKey("Scuba"))")
    }

    // T7 — ⭐ the assertion that makes the Epic's D3 tag split possible. Two
    // tags sharing a display name with different kinds are DIFFERENT nodes.
    // Identity on name alone would refuse the split v28 exists to allow.
    func testTwoTagsSharingANameWithDifferentKindsAreDistinct() {
        let action = NodeIdentity(type: "tag", tagKind: "action", displayName: "Massage")
        let attribute = NodeIdentity(type: "tag", tagKind: "attribute", displayName: "Massage")
        XCTAssertNotEqual(action.resolutionKey, attribute.resolutionKey)
        XCTAssertNotEqual(action, attribute)
    }

    // T8 — a kind is part of identity, so nil and a set kind are not the same
    // node. An unclassified tag learning its kind is an upgrade the merge
    // handles; it must not read as a different tag arriving.
    func testAnUnclassifiedTagIsNotTheSameNodeAsAClassifiedOne() {
        let unclassified = NodeIdentity(type: "tag", displayName: "Massage")
        let classified = NodeIdentity(type: "tag", tagKind: "action", displayName: "Massage")
        XCTAssertNotEqual(unclassified.resolutionKey, classified.resolutionKey)
    }

    // T9 — ⚠️ the separator cannot be forged out of field contents. A name
    // containing the delimiter must not be able to impersonate another node's
    // key, which is why it is a control character rather than a colon or pipe.
    func testAKeyCannotBeForgedByANameContainingTheSeparator() {
        let odd = NodeIdentity(type: "tag", tagKind: nil, displayName: "a\u{1F}b")
        let split = NodeIdentity(type: "tag", tagKind: "a", displayName: "b")
        XCTAssertNotEqual(odd.resolutionKey, split.resolutionKey)
    }

    // T10 — a profile hands out its own identity, so callers never parse ids
    // themselves. After the re-keying this is the ONE place that changes.
    func testAProfileReportsItsTravellingIdentity() {
        let profile = EntityProfile(id: "actor:Marta Venlowe")
        XCTAssertEqual(profile.nodeIdentity,
                       NodeIdentity(type: "actor", displayName: "Marta Venlowe"))
    }

    // T11 — the identity survives JSON, since that is how it will travel.
    func testTheIdentitySurvivesAFileRoundTrip() throws {
        let original = NodeIdentity(type: "tag", tagKind: "action", displayName: "Massage")
        let decoded = try JSONDecoder().decode(
            NodeIdentity.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.resolutionKey, original.resolutionKey)
    }
}
