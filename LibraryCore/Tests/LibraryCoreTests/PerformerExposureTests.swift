// PerformerExposureTests.swift
// #62 — a performer's NAME reaches no provider unless their videos say it may.
//
// 🚨 Same discipline as `ProviderBoundaryTests`: the structural assertion is made
// against a double that FAILS IF IT IS CALLED AT ALL. "The search returned
// nothing" would pass just as happily against a provider that was contacted and
// answered nothing — and what is being protected is that the name is never sent,
// not that the answer is thrown away.

import XCTest
@testable import LibraryCore

/// An actor provider that fails the test on contact.
private final class NameMustNeverBeSentProvider: ActorMetadataProvider, @unchecked Sendable {
    let id = "name-must-never-be-sent"
    let displayName = "Name Must Never Be Sent"
    let summary = "A test double that fails if a name search is constructed."
    let capabilities: Set<PluginCapability> = [.actorMetadata]
    let credentialRequirement: CredentialRequirement = .none
    let attribution: String? = nil
    let homepage: URL? = nil

    private(set) var wasContacted = false

    private func contacted(_ what: String) {
        wasContacted = true
        XCTFail("\(what) was constructed for a performer whose name must never be sent")
    }

    func search(name: String) async throws -> [PluginCandidate] {
        contacted("A name search for “\(name)”"); return []
    }

    func fetch(actorId: String) async throws -> ActorMetadataProposal {
        contacted("A fetch")
        throw CancellationError()
    }
}

final class PerformerExposureTests: XCTestCase {

    private func asset(_ actors: [String], _ kind: ContentKind?) -> Asset {
        Asset(relativePath: "\(UUID().uuidString).mp4",
              fileName: "a.mp4",
              tags: actors.map { "actor:\($0)" },
              contentKind: kind)
    }

    private func index(_ profiles: [EntityProfile] = []) -> EntityProfileIndex {
        EntityProfileIndex(profiles)
    }

    // MARK: - P1–P4 · the rule

    /// ⭐ The line that was argued about, and the Human Operator's answer
    /// (2026-08-15). One declared commercial credit is enough — a commercial
    /// performer's name was never private, and refusing on any personal
    /// appearance would block a real performer because the operator tagged them
    /// in one home video.
    func testP1OneCommercialCreditGrantsExposureDespiteAPersonalAppearance() {
        XCTAssertNil(PerformerExposure.refusal(forVideoKinds: [.personal, .scene]))
        XCTAssertTrue(PerformerExposure.allows([.scene, .personal, nil]))
    }

    func testP2APerformerSeenOnlyInPersonalVideosIsRefused() {
        XCTAssertEqual(PerformerExposure.refusal(forVideoKinds: [.personal]),
                       .personalOnly)
        XCTAssertEqual(PerformerExposure.refusal(forVideoKinds: [.personal, .personal]),
                       .personalOnly)
    }

    /// 🚨 The case that decides the whole feature in practice. Every one of the
    /// 2,077 videos on the drive is undeclared, so reading "not personal" as
    /// "safe" would send the entire cast list on day one.
    func testP3APerformerWithOnlyUndeclaredVideosIsRefused() {
        XCTAssertEqual(PerformerExposure.refusal(forVideoKinds: [nil]), .undeclared)
        XCTAssertEqual(PerformerExposure.refusal(forVideoKinds: [nil, nil, nil]), .undeclared)
    }

    /// ⚠️ Undecidable is not the same as safe — the `nil`-content-kind rule one
    /// level up. One profile in the drive library is in exactly this state.
    func testP4APerformerWithNoVideosAtAllIsRefused() {
        XCTAssertEqual(PerformerExposure.refusal(forVideoKinds: []), .noVideos)
        XCTAssertFalse(PerformerExposure.allows([]))
    }

    /// The mixed refusal reports the ACTIONABLE half. Both are refusals, but
    /// only one of them tells the operator what to do about it, and calling a
    /// merely-undeclared set "your own videos" states something the library
    /// cannot support.
    func testP5PersonalPlusUndeclaredReportsTheUndeclaredOne() {
        XCTAssertEqual(PerformerExposure.refusal(forVideoKinds: [.personal, nil]),
                       .undeclared)
    }

    // MARK: - P6–P7 · derived from the library, by the same crediting rule

    func testP6ExposureIsDerivedFromTheVideosThatCreditThem() {
        let assets = [
            asset(["Vera Example"], .scene),
            asset(["Family Member"], .personal),
            asset(["Undeclared Person"], nil),
        ]
        let exposures = PerformerExposure.build(assets: assets, profiles: index())

        XCTAssertNil(PerformerExposure.refusal(forPerformer: "Vera Example", in: exposures))
        XCTAssertEqual(PerformerExposure.refusal(forPerformer: "Family Member", in: exposures),
                       .personalOnly)
        XCTAssertEqual(PerformerExposure.refusal(forPerformer: "Undeclared Person", in: exposures),
                       .undeclared)
    }

    /// ⭐ Crediting runs through AKAs, exactly as the video count beside it does.
    /// A performer whose only commercial credit is under an alias is exposed by
    /// it — and a rule that missed the alias would refuse a name that is public,
    /// which is the failure that makes a boundary get switched off.
    func testP7AnAliasCreditsTowardsExposure() {
        var profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Vera Example")
        profile.akas = ["V. Example"]

        let assets = [asset(["V. Example"], .film), asset(["Vera Example"], .personal)]
        let exposures = PerformerExposure.build(assets: assets, profiles: index([profile]))

        XCTAssertNil(PerformerExposure.refusal(forPerformer: "Vera Example", in: exposures),
                     "the commercial credit under an alias is still theirs")
    }

    /// ⚠️ The crediting rule must be the SAME one the displayed count uses. If
    /// these diverged, a performer would read as "in 3 of your videos" on one
    /// screen and be judged on a different three by the boundary — invisibly,
    /// and in the unrecoverable direction.
    func testP8ExposureCreditsExactlyWhatTheVideoCountCounts() {
        var profile = EntityProfile(id: UUID().uuidString, entityType: "actor",
                                    displayName: "Vera Example")
        profile.akas = ["V. Example"]
        let assets = [
            asset(["Vera Example"], .scene),
            asset(["V. Example"], .personal),
            asset(["Vera Example", "V. Example"], nil),   // credits once
            asset(["Someone Else"], .scene),
        ]
        let profiles = index([profile])

        let credited = ActorCredits.byActor(assets: assets, profiles: profiles)
        let counts = ActorVideoCounts.build(assets: assets, profiles: profiles)
        let exposures = PerformerExposure.build(assets: assets, profiles: profiles)

        XCTAssertEqual(credited["Vera Example"]?.count, counts["Vera Example"])
        XCTAssertEqual(counts["Vera Example"], 3)
        XCTAssertEqual(Set(exposures.keys), Set(counts.keys),
                       "every counted performer must have an exposure, and vice versa")
    }

    // MARK: - P9 · the inversion guard

    /// 🚨 A performer nobody credits is ABSENT from the map, and absent must
    /// read as refused. `exposures[name] == nil` would say "allowed" — the exact
    /// inversion this boundary exists to prevent, and it compiles.
    func testP9AnUnknownPerformerIsRefusedRatherThanAllowed() {
        let exposures = PerformerExposure.build(assets: [asset(["Vera Example"], .scene)],
                                                profiles: index())
        XCTAssertEqual(PerformerExposure.refusal(forPerformer: "Nobody At All", in: exposures),
                       .noVideos)
    }

    // MARK: - P10–P11 · the boundary, asserted structurally

    private func registryWithDouble() -> (PluginRegistry, NameMustNeverBeSentProvider) {
        let registry = PluginRegistry()
        let double = NameMustNeverBeSentProvider()
        registry.register(double)
        registry.setEnabled(true, pluginId: double.id)
        return (registry, double)
    }

    /// The registry hands back NO provider, so there is nothing to call. The
    /// refusal happens before a search can be constructed — not inside a loop
    /// that chose to skip, which would be a property of one caller.
    func testP10TheRegistryHandsBackNoProviderForARefusedPerformer() {
        let (registry, double) = registryWithDouble()
        XCTAssertFalse(registry.installedActorProviders().isEmpty,
                       "the double must be installed, or this test proves nothing")

        let exposures = PerformerExposure.build(
            assets: [asset(["Family Member"], .personal), asset(["Undeclared"], nil)],
            profiles: index())

        for name in ["Family Member", "Undeclared", "Never Heard Of Them"] {
            XCTAssertTrue(registry.actorProviders(forPerformer: name, in: exposures).isEmpty,
                          "\(name) must reach no provider")
        }
        XCTAssertFalse(double.wasContacted)
    }

    func testP11ACommercialPerformerStillReachesTheirProvider() {
        let (registry, double) = registryWithDouble()
        let exposures = PerformerExposure.build(assets: [asset(["Vera Example"], .scene)],
                                                profiles: index())

        XCTAssertEqual(registry.actorProviders(forPerformer: "Vera Example",
                                               in: exposures).count, 1,
                       "the boundary must not block an ordinary commercial performer")
        XCTAssertFalse(double.wasContacted, "obtaining a provider is not contacting it")
    }

    /// The operator has to be able to tell "never" from "not yet" from
    /// "nothing to go on" — three refusals, three explanations.
    func testP12EachRefusalExplainsItselfDistinctly() {
        let reasons = Set([PerformerExposure.Refusal.personalOnly.reason,
                           PerformerExposure.Refusal.undeclared.reason,
                           PerformerExposure.Refusal.noVideos.reason])
        XCTAssertEqual(reasons.count, 3)

        let exposures = PerformerExposure.build(assets: [asset(["Mine"], .personal)],
                                                profiles: index())
        XCTAssertEqual(PluginRegistry().refusalForActorLookup(ofPerformer: "Mine",
                                                              in: exposures),
                       .personalOnly)
    }
}
