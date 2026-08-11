// ActorEnrichmentModelTests.swift
// The app layer's first unit tests.
//
// 🚨 Three of this session's six defects lived in view models, which had no
// unit target at all — only `ViLMUITests`. The domain suite could not reach
// them, so they were verified by running the app on a phone and noticing.
//
// `localName` is the one that reached the operator twice. It read the actor's
// name by splitting the id on ":" and returning the whole string when there
// was none — so after the re-key every actor reported its own uid. Not
// cosmetic: `proposedName` compared the source's title to that uid, so a
// rename was offered on EVERY match even when the spellings were identical,
// and `renameWouldBeNoOp` could not recognise the no-op, so the rename fired
// against a tag that does not exist.

import XCTest
import LibraryCore
@testable import ViLM

@MainActor
final class ActorEnrichmentModelTests: XCTestCase {

    /// A provider is required to build the model but is never called by these
    /// tests — nothing here reaches the network.
    private struct SilentProvider: ActorMetadataProvider {
        let id = "test.silent"
        let displayName = "TheSource"
        let summary = ""
        let capabilities: Set<PluginCapability> = [.actorMetadata]
        let credentialRequirement: CredentialRequirement = .none
        func search(name: String) async throws -> [PluginCandidate] { [] }
        func fetch(actorId: String) async throws -> ActorMetadataProposal { .init() }
        func knownWorks(actorId: String, limit: Int) async throws -> [PluginCandidate] { [] }
    }

    private func model(entityId: String, entityName: String,
                       profile: EntityProfile?) -> ActorEnrichmentModel {
        ActorEnrichmentModel(provider: SilentProvider(), entityId: entityId,
                             entityName: entityName, currentProfile: profile)
    }

    // MARK: - 🚨 The name never comes from the id

    func testAUidKeyedActorReportsItsNameNotItsUid() {
        let uid = UUID().uuidString
        var profile = EntityProfile(id: uid, entityType: "actor", displayName: "Ann Example")
        profile.enrichmentSourceId = "p-1"

        let m = model(entityId: uid, entityName: "Ann Example", profile: profile)

        XCTAssertEqual(m.localName, "Ann Example")
        XCTAssertNotEqual(m.localName, uid, "the defect the operator saw twice")
    }

    /// ⭐ The stored column wins over the name the sheet was opened with —
    /// they can differ after a rename elsewhere, and the row is the truth.
    func testTheStoredNameWinsOverTheOpeningName() {
        let uid = UUID().uuidString
        let profile = EntityProfile(id: uid, entityType: "actor", displayName: "Ann Example")

        let m = model(entityId: uid, entityName: "Stale Opening Name", profile: profile)

        XCTAssertEqual(m.localName, "Ann Example")
    }

    /// With no row yet, the name the caller opened with is all there is — and
    /// it is still a name, not a uid.
    func testWithNoProfileTheOpeningNameIsUsed() {
        let uid = UUID().uuidString

        let m = model(entityId: uid, entityName: "Ann Example", profile: nil)

        XCTAssertEqual(m.localName, "Ann Example")
    }

    /// ⚠️ A library that has NOT been re-keyed still works — the id-derived
    /// name is the last fallback, not the first choice.
    func testALegacyKeyedActorStillResolves() {
        let m = model(entityId: "actor:Ann Example", entityName: "", profile: nil)

        XCTAssertEqual(m.localName, "Ann Example")
    }

    /// A damaged row genuinely has no name, and reporting its uid is honest —
    /// that is what *Missing Identities* shows and what it is called there.
    func testANamelessRowHonestlyReportsItsUid() {
        let uid = UUID().uuidString

        let m = model(entityId: uid, entityName: uid, profile: EntityProfile(id: uid))

        XCTAssertEqual(m.localName, uid)
    }

    // MARK: - 🚨 What depended on it

    /// The consequence that mattered. With the name read correctly, a source
    /// spelling identical to ours is recognised as no change at all.
    func testAnIdenticalSourceSpellingOffersNoRename() {
        let uid = UUID().uuidString
        let profile = EntityProfile(id: uid, entityType: "actor", displayName: "Ann Example")
        let m = model(entityId: uid, entityName: "Ann Example", profile: profile)

        m.acceptCandidateForTesting(.init(id: "p-1", title: "Ann Example"))

        XCTAssertNil(m.proposedName, "the spellings agree")
        XCTAssertTrue(m.renameWouldBeNoOp)
        XCTAssertNil(m.acceptedCanonicalName, "so nothing is renamed")
    }

    /// ⭐ And a genuinely different spelling is still offered.
    func testADifferentSourceSpellingIsStillOffered() {
        let uid = UUID().uuidString
        let profile = EntityProfile(id: uid, entityType: "actor", displayName: "Ann Exampel")
        let m = model(entityId: uid, entityName: "Ann Exampel", profile: profile)

        m.acceptCandidateForTesting(.init(id: "p-1", title: "Ann Example"))

        XCTAssertEqual(m.proposedName, "Ann Example")
        XCTAssertFalse(m.renameWouldBeNoOp)
        XCTAssertEqual(m.acceptedCanonicalName, "Ann Example")
    }
}
