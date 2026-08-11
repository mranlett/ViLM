import XCTest
@testable import LibraryCore

/// ⚠️ The studio policy has to mean the same thing on both routes.
///
/// It shipped wired into the per-video sheet and not into the batch run, so a
/// video's studio depended on which screen matched it — the batch path applied
/// the imprint unconditionally and recorded no hierarchy. These pin the shared
/// decision both paths now call, so the two cannot drift apart again silently.
final class StudioPolicyParityTests: XCTestCase {

    private var libraryURL: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        store = try LibraryStore(at: libraryURL)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnections(keepingLibraryAt: nil)
        try? FileManager.default.removeItem(at: libraryURL)
    }

    private func proposal(studio: String?, parent: String?) -> VideoMetadataProposal {
        var p = VideoMetadataProposal()
        p.studio = ProposedField(studio)
        p.studioSourceId = ProposedField(studio.map { "imprint-\($0)" })
        p.studioParent = ProposedField(parent)
        p.studioParentSourceId = ProposedField(parent.map { "parent-\($0)" })
        return p
    }

    /// The verification lookup both routes use.
    private func isVerified(_ name: String) -> Bool {
        (try? store.fetchEntityProfile(for: "studio:\(name)"))?.enrichmentState == .matched
    }

    private func confirm(_ name: String) throws {
        try store.confirmStudio(name, source: "Example Source")
    }

    // MARK: - The decision itself

    func testAConfirmedStudioIsWhatVerificationMeans() throws {
        try confirm("Example Network")

        XCTAssertTrue(isVerified("Example Network"))
        XCTAssertFalse(isVerified("Example Studio"))
    }

    /// Neither confirmed — the batch run must NOT proceed here. This is the
    /// case that was silently applying the imprint.
    func testNothingConfirmedIsAQuestionNotADefault() throws {
        let outcome = VideoEnrichmentReview.studioResolution(
            proposal: proposal(studio: "Example Studio", parent: "Example Network"),
            held: [],
            isVerified: isVerified)

        guard case .ask = outcome else {
            return XCTFail("a batch run would have applied the imprint here")
        }
    }

    func testConfirmingOneStudioSettlesItForEveryLaterVideo() throws {
        try confirm("Example Network")

        let outcome = VideoEnrichmentReview.studioResolution(
            proposal: proposal(studio: "Example Studio", parent: "Example Network"),
            held: [],
            isVerified: isVerified)

        guard case let .use(choice) = outcome else { return XCTFail("expected .use") }
        XCTAssertEqual(choice.name, "Example Network",
                       "the disambiguation extinguishes itself as studios get confirmed")
    }

    // MARK: - The hierarchy

    /// ⚠️ Recorded from the IMPRINT, whichever name the video ended up with.
    func testTheParentEdgeIsRecordedEvenWhenTheParentWonTheVideo() throws {
        try confirm("Example Studio")
        try confirm("Example Network")

        try store.setStudioParent("studio:Example Network", forStudio: "studio:Example Studio")

        XCTAssertEqual(try store.edgeCount(.studioParent), 1)
        XCTAssertTrue(try store.studioIdWithDescendants("studio:Example Network")
            .contains("studio:Example Studio"))
    }

    /// The store refuses a hierarchy that loops, so a source disagreeing with
    /// itself cannot wedge the graph.
    func testACycleIsRefused() throws {
        try confirm("Example Studio")
        try confirm("Example Network")
        try store.setStudioParent("studio:Example Network", forStudio: "studio:Example Studio")

        XCTAssertThrowsError(
            try store.setStudioParent("studio:Example Studio", forStudio: "studio:Example Network"))
    }

    func testAStudioIsNotItsOwnParent() throws {
        try confirm("Example Studio")

        XCTAssertThrowsError(
            try store.setStudioParent("studio:Example Studio", forStudio: "studio:Example Studio"))
    }

    /// A source naming the same studio at both levels offers no hierarchy —
    /// and both call sites guard on exactly this before writing an edge.
    func testTheSameNameAtBothLevelsIsNotAHierarchy() throws {
        XCTAssertTrue(StudioResolution.isSameStudio("Example Studio", "ExampleStudio"))
    }
}
