import XCTest
@testable import LibraryCore

/// Carrying the graph — minus the videos — from one library to another.
final class GraphSyncTests: XCTestCase {

    private var aURL: URL!, bURL: URL!
    private var a: LibraryStore!, b: LibraryStore!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphSync-\(UUID().uuidString)", isDirectory: true)
        aURL = root.appendingPathComponent("a", isDirectory: true)
        bURL = root.appendingPathComponent("b", isDirectory: true)
        for url in [aURL!, bURL!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        a = try LibraryStore(at: aURL)
        b = try LibraryStore(at: bURL)
    }

    override func tearDownWithError() throws {
        a = nil; b = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: aURL.deletingLastPathComponent())
    }

    private func studio(_ store: LibraryStore, _ name: String, confirmed: Bool = false) throws {
        if confirmed {
            try store.confirmStudio(name, source: "Example Source")
        } else {
            try store.saveEntityProfile(EntityProfile(id: "studio:\(name)"))
        }
    }

    // MARK: - What travels

    func testStudiosTravel() throws {
        try studio(a, "Example Studio", confirmed: true)

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.newStudios, 1)
        XCTAssertEqual(try b.fetchEntityProfile(for: "studio:Example Studio")?.enrichmentState,
                       .matched, "including the confirmation, or B asks about it again")
    }

    /// ⚠️ Kinds travel with the tags. Without them the receiving library treats
    /// every arriving tag as unclassified and can attach none of them.
    func testTagsTravelWithTheirKinds() throws {
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.newTags, 1)
        XCTAssertEqual(try b.fetchTagVocabulary().first?.resolvedKind(), TagKind.action)
    }

    func testPerformerTraitsAndStudioHierarchyTravel() throws {
        try a.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        try a.saveTagRecord(TagRecord(displayName: "Tall", kind: .performerAttribute))
        try a.linkTag(TagNormalizer.identityKey("Tall"), toPerformer: "actor:Alice Example")
        try studio(a, "Example Studio"); try studio(a, "Example Network")
        try a.setStudioParent("studio:Example Network", forStudio: "studio:Example Studio")

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.newPerformerTags, 1)
        XCTAssertEqual(result.newStudioParents, 1)
        XCTAssertTrue(try b.studioIdWithDescendants("studio:Example Network")
            .contains("studio:Example Studio"))
    }

    // MARK: - ⚠️ What must NOT travel

    /// A video lives in one library and its id is local to it. An edge naming
    /// one would point at nothing on the other side.
    func testVideosAndTheirEdgesDoNotTravel() throws {
        try a.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4", tags: ["actor:Alice Example"])
        try a.insertAsset(asset)
        try a.connectEdges(forVideo: asset.id)
        XCTAssertEqual(try a.edgeCount(.videoPerformer), 1)

        try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertTrue(try b.fetchAllAssets().isEmpty, "no videos")
        XCTAssertEqual(try b.edgeCount(.videoPerformer), 0, "and no edges naming one")
    }

    // MARK: - ⚠️ Additive: a sync never overrules the receiving library

    func testAClassifiedTagIsNotReclassifiedFromOutside() throws {
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .videoAttribute))
        try b.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.classifiedTags, 0)
        XCTAssertEqual(try b.fetchTagVocabulary().first?.resolvedKind(), TagKind.action,
                       "B's operator decided this; a sync must not silently overrule it")
    }

    /// The one upgrade allowed: learning a kind it did not have. That is
    /// knowledge, not a competing opinion.
    func testAnUnclassifiedTagMayLearnItsKind() throws {
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        try b.saveTagRecord(TagRecord(displayName: "Climbing", kind: nil))

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.classifiedTags, 1)
        XCTAssertEqual(try b.fetchTagVocabulary().first?.resolvedKind(), TagKind.action)
    }

    func testAnUnconfirmedStudioMayLearnItIsConfirmed() throws {
        try studio(a, "Example Studio", confirmed: true)
        try studio(b, "Example Studio")

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.updatedStudios, 1)
        XCTAssertEqual(try b.fetchEntityProfile(for: "studio:Example Studio")?.enrichmentState,
                       .matched)
    }

    func testNothingIsRemovedFromTheReceivingLibrary() throws {
        try studio(b, "Only In B")
        try b.saveTagRecord(TagRecord(displayName: "Only In B", kind: .action))

        try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertNotNil(try b.fetchEntityProfile(for: "studio:Only In B"))
        XCTAssertEqual(try b.fetchTagVocabulary().count, 1)
    }

    // MARK: - Edges whose ends are missing

    /// Skipped rather than conjuring the node the edge names.
    func testAnEdgeNamingSomethingUnknownIsSkipped() throws {
        try a.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        try a.saveTagRecord(TagRecord(displayName: "Tall", kind: .performerAttribute))
        try a.linkTag(TagNormalizer.identityKey("Tall"), toPerformer: "actor:Alice Example")

        // B is given only the edges, never the nodes.
        var stripped = try a.exportGraph(includingPhotoData: false)
        stripped = ActorLibraryExport(formatVersion: stripped.formatVersion,
                                      exportedAt: stripped.exportedAt,
                                      profiles: [], photos: [])
        stripped.performerTags = try a.performerTagPairs()

        let result = try b.applyGraphMerge(stripped)

        XCTAssertEqual(result.newPerformerTags, 0)
        XCTAssertEqual(try b.edgeCount(.performerTag), 0)
    }

    // MARK: - Running it twice

    func testASecondSyncChangesNothing() throws {
        try studio(a, "Example Studio", confirmed: true)
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        try a.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        try a.linkTag(TagNormalizer.identityKey("Climbing"), toPerformer: "actor:Alice Example")

        try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))
        let second = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        // ⚠️ Scoped to the graph portions deliberately. The actor merge counts
        // a matched profile as "updated" whether or not any value differed —
        // its own long-standing behaviour, tested elsewhere — so asserting on
        // the combined total here would be testing that, not this.
        XCTAssertEqual(second.newStudios, 0)
        XCTAssertEqual(second.updatedStudios, 0)
        XCTAssertEqual(second.newTags, 0)
        XCTAssertEqual(second.classifiedTags, 0)
        XCTAssertEqual(second.newPerformerTags, 0)
        XCTAssertEqual(second.newStudioParents, 0)
    }

    /// ⚠️ Two libraries can each hold half of a hierarchy that only loops once
    /// combined. One bad pairing is counted and skipped, never thrown — it must
    /// not abandon an otherwise good sync partway through.
    func testALoopingHierarchyIsRefusedWithoutAbortingTheSync() throws {
        try studio(a, "Example Studio"); try studio(a, "Example Network")
        try a.setStudioParent("studio:Example Studio", forStudio: "studio:Example Network")
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))

        try studio(b, "Example Studio"); try studio(b, "Example Network")
        try b.setStudioParent("studio:Example Network", forStudio: "studio:Example Studio")

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.refusedCycles, 1)
        XCTAssertEqual(result.newTags, 1, "and the rest of the sync still landed")
    }
}

/// The LIVE path — two attached libraries converged in place, no export file.
/// It used to carry actors only, so the two ways to sync produced different
/// libraries.
final class LiveGraphSyncTests: XCTestCase {

    private var aURL: URL!, bURL: URL!
    private var a: LibraryStore!, b: LibraryStore!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveSync-\(UUID().uuidString)", isDirectory: true)
        aURL = root.appendingPathComponent("a", isDirectory: true)
        bURL = root.appendingPathComponent("b", isDirectory: true)
        for url in [aURL!, bURL!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        a = try LibraryStore(at: aURL)
        b = try LibraryStore(at: bURL)
    }

    override func tearDownWithError() throws {
        a = nil; b = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: aURL.deletingLastPathComponent())
    }

    func testASnapshotCarriesTheWholeGraph() throws {
        try a.confirmStudio("Example Studio", source: "Example Source")
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))

        let snapshot = try ActorSync.snapshot(of: aURL)

        XCTAssertEqual(snapshot.export.studios.count, 1)
        XCTAssertEqual(snapshot.export.tags.count, 1)
    }

    /// The union travels both ways, so converging leaves both libraries the
    /// same rather than only topping up one of them.
    func testConvergingCarriesEachLibrarysStudiosToTheOther() throws {
        try a.confirmStudio("Only In A", source: "Example Source")
        try b.confirmStudio("Only In B", source: "Example Source")

        let snapshots = [try ActorSync.snapshot(of: aURL), try ActorSync.snapshot(of: bURL)]
        let converged = ActorSync.convergedExport(actorIds: [], resolutions: [:],
                                                  snapshots: snapshots)
        try ActorSync.apply(converged, to: aURL)
        try ActorSync.apply(converged, to: bURL)

        XCTAssertNotNil(try a.fetchEntityProfile(for: "studio:Only In B"))
        XCTAssertNotNil(try b.fetchEntityProfile(for: "studio:Only In A"))
    }

    func testTagKindsSurviveTheUnion() throws {
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        try b.saveTagRecord(TagRecord(displayName: "Climbing", kind: nil))

        let snapshots = [try ActorSync.snapshot(of: aURL), try ActorSync.snapshot(of: bURL)]
        let converged = ActorSync.convergedExport(actorIds: [], resolutions: [:],
                                                  snapshots: snapshots)
        try ActorSync.apply(converged, to: bURL)

        XCTAssertEqual(try b.fetchTagVocabulary().first?.resolvedKind(), TagKind.action,
                       "B learns the kind it did not have")
    }

    /// ⚠️ A genuine disagreement leaves BOTH sides as they were. Nothing is
    /// lost, but nothing asks the operator either — the known gap.
    func testADisagreementOverAKindChangesNeitherLibrary() throws {
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        try b.saveTagRecord(TagRecord(displayName: "Climbing", kind: .videoAttribute))

        let snapshots = [try ActorSync.snapshot(of: aURL), try ActorSync.snapshot(of: bURL)]
        let converged = ActorSync.convergedExport(actorIds: [], resolutions: [:],
                                                  snapshots: snapshots)
        try ActorSync.apply(converged, to: aURL)
        try ActorSync.apply(converged, to: bURL)

        XCTAssertEqual(try a.fetchTagVocabulary().first?.resolvedKind(), TagKind.action)
        XCTAssertEqual(try b.fetchTagVocabulary().first?.resolvedKind(), TagKind.videoAttribute)
    }

    func testNoVideoEverTravelsOnTheLivePath() throws {
        try a.saveEntityProfile(EntityProfile(id: "actor:Alice Example"))
        let asset = Asset(relativePath: "a.mp4", fileName: "a.mp4", tags: ["actor:Alice Example"])
        try a.insertAsset(asset)
        try a.connectEdges(forVideo: asset.id)

        let snapshots = [try ActorSync.snapshot(of: aURL), try ActorSync.snapshot(of: bURL)]
        let converged = ActorSync.convergedExport(actorIds: ["actor:Alice Example"],
                                                  resolutions: [:], snapshots: snapshots)
        try ActorSync.apply(converged, to: bURL)

        XCTAssertTrue(try b.fetchAllAssets().isEmpty)
        XCTAssertEqual(try b.edgeCount(.videoPerformer), 0)
    }
}

/// ⚠️ A sync that changes nothing is safe. A sync that changes nothing and
/// SAYS nothing leaves a library quietly holding a different answer from its
/// twin, and no way to find out.
final class GraphSyncDisagreementTests: XCTestCase {

    private var aURL: URL!, bURL: URL!
    private var a: LibraryStore!, b: LibraryStore!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Disagree-\(UUID().uuidString)", isDirectory: true)
        aURL = root.appendingPathComponent("a", isDirectory: true)
        bURL = root.appendingPathComponent("b", isDirectory: true)
        for url in [aURL!, bURL!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        a = try LibraryStore(at: aURL)
        b = try LibraryStore(at: bURL)
    }

    override func tearDownWithError() throws {
        a = nil; b = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: aURL.deletingLastPathComponent())
    }

    func testATagClassifiedTwoWaysIsReported() throws {
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .videoAttribute))
        try b.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.disagreements.count, 1)
        let item = try XCTUnwrap(result.disagreements.first)
        XCTAssertEqual(item.subject, .tagKind)
        XCTAssertEqual(item.mine, "action")
        XCTAssertEqual(item.theirs, "video-attribute")
        XCTAssertEqual(try b.fetchTagVocabulary().first?.resolvedKind(), TagKind.action,
                       "reported, and still not overruled")
    }

    func testAStudioConfirmedAgainstTwoSourcesIsReported() throws {
        try a.confirmStudio("Example Studio", source: "Source A")
        try b.confirmStudio("Example Studio", source: "Source B")

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertEqual(result.disagreements.first?.subject, .studioSource)
        XCTAssertEqual(try b.fetchEntityProfile(for: "studio:Example Studio")?.enrichmentSource,
                       "Source B")
    }

    /// Agreement is not a disagreement, and neither is a gap being filled.
    func testAgreementAndGapsReportNothing() throws {
        try a.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        try b.saveTagRecord(TagRecord(displayName: "Climbing", kind: .action))
        try a.saveTagRecord(TagRecord(displayName: "Anthology", kind: .videoAttribute))
        try b.saveTagRecord(TagRecord(displayName: "Anthology", kind: nil))

        let result = try b.applyGraphMerge(try a.exportGraph(includingPhotoData: false))

        XCTAssertTrue(result.disagreements.isEmpty)
        XCTAssertEqual(result.classifiedTags, 1)
    }
}
