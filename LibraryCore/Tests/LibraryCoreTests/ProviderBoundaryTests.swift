// ProviderBoundaryTests.swift
// T16 / PA4 — personal and undeclared content reach no provider (#59).
//
// 🚨 The central assertion is made against a double that FAILS IF IT IS CALLED
// AT ALL. Asserting "the result was empty" would pass just as happily against a
// provider that was called and returned nothing — and the thing being protected
// is that the request is never constructed, not that its answer is discarded.

import XCTest
@testable import LibraryCore

/// A provider that fails the test on contact.
///
/// ⭐ Nothing here returns data. Every method records a violation, because for
/// personal content there is no correct number of requests other than zero.
private final class MustNeverBeCalledProvider: VideoMetadataProvider, @unchecked Sendable {
    let id = "must-never-be-called"
    let displayName = "Must Never Be Called"
    let summary = "A test double that fails if a request is constructed."
    let capabilities: Set<PluginCapability> = [.videoMetadata]
    let credentialRequirement: CredentialRequirement = .none
    let attribution: String? = nil
    let homepage: URL? = nil

    /// Set when the boundary leaked. Checked by the test, not by the double, so
    /// a failure names the case rather than the double.
    private(set) var wasContacted = false

    private func contacted(_ what: String) {
        wasContacted = true
        XCTFail("\(what) was constructed for content that must never leave the device")
    }

    func search(title: String, year: Int?) async throws -> [PluginCandidate] {
        contacted("A title search"); return []
    }

    func fetch(videoId: String) async throws -> VideoMetadataProposal {
        contacted("A fetch")
        throw CancellationError()
    }
}

final class ProviderBoundaryTests: XCTestCase {

    private func asset(_ kind: ContentKind?) -> Asset {
        Asset(relativePath: "a.mp4", fileName: "a.mp4", contentKind: kind)
    }

    // MARK: - The rule

    func testPersonalContentIsRefused() {
        XCTAssertEqual(ProviderBoundary.refusal(for: .personal), .personalContent)
        XCTAssertFalse(ProviderBoundary.allows(.personal))
    }

    /// 🚨 The one that decides everything. `nil` is where all 2,000+ rows begin,
    /// so reading it as "not personal" would have opened the boundary across the
    /// whole library the day it shipped. Fail closed.
    func testUndeclaredContentIsRefused() {
        XCTAssertEqual(ProviderBoundary.refusal(for: nil), .undeclared)
        XCTAssertFalse(ProviderBoundary.allows(nil))
    }

    func testCommercialKindsAreAllowed() {
        for kind in [ContentKind.scene, .film, .episodic] {
            XCTAssertNil(ProviderBoundary.refusal(for: kind), "\(kind) should be allowed")
        }
    }

    /// ⚠️ Every kind is decided explicitly. A case added later without a
    /// decision would otherwise inherit whichever branch it happened to fall
    /// into — and the unsafe branch is the silent one.
    func testEveryKindHasADecision() {
        let refused = ContentKind.allCases.filter { !ProviderBoundary.allows($0) }
        XCTAssertEqual(refused, [.personal],
                       "a new content kind was added without deciding whether it may be sent")
    }

    // MARK: - The boundary, asserted structurally

    /// T16 / PA4. The registry hands back NO provider, so there is nothing to
    /// call — the refusal happens before a request can be constructed.
    func testTheRegistryHandsBackNoProviderForPersonalOrUndeclaredContent() {
        let registry = PluginRegistry()
        let double = MustNeverBeCalledProvider()
        registry.register(double)
        registry.setEnabled(true, pluginId: double.id)

        XCTAssertFalse(registry.installedVideoProviders().isEmpty,
                       "the double must be installed, or this test proves nothing")

        XCTAssertTrue(registry.videoProviders(for: asset(.personal)).isEmpty)
        XCTAssertTrue(registry.videoProviders(for: asset(nil)).isEmpty)
        XCTAssertFalse(double.wasContacted)
    }

    func testDeclaredCommercialContentStillReachesItsProvider() {
        let registry = PluginRegistry()
        let double = MustNeverBeCalledProvider()
        registry.register(double)
        registry.setEnabled(true, pluginId: double.id)

        XCTAssertEqual(registry.videoProviders(for: asset(.scene)).count, 1,
                       "the boundary must not block ordinary content")
        XCTAssertFalse(double.wasContacted, "obtaining a provider is not contacting it")
    }

    func testTheRefusalExplainsItself() {
        XCTAssertEqual(registryRefusal(.personal), .personalContent)
        XCTAssertEqual(registryRefusal(nil), .undeclared)
        XCTAssertNil(registryRefusal(.film))
        // The operator has to be able to tell "never" from "not yet".
        XCTAssertNotEqual(ProviderBoundary.Refusal.personalContent.reason,
                          ProviderBoundary.Refusal.undeclared.reason)
    }

    private func registryRefusal(_ kind: ContentKind?) -> ProviderBoundary.Refusal? {
        PluginRegistry().refusalForVideoLookup(of: asset(kind))
    }

    // MARK: - Round trip

    /// ⚠️ A field can compile, run and never persist — `Asset` wires its columns
    /// by hand in five places. This is what catches a missed one.
    func testTheDeclarationSurvivesAStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            LibraryStore.evictCachedConnection(forLibraryAt: dir)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = try LibraryStore(at: dir)

        for kind in ContentKind.allCases {
            let a = Asset(relativePath: "\(kind.rawValue).mp4",
                          fileName: "\(kind.rawValue).mp4", contentKind: kind)
            try store.insertAsset(a)
            XCTAssertEqual(try store.fetchAllAssets().first { $0.id == a.id }?.contentKind, kind)
        }

        // And undeclared stays undeclared rather than defaulting to something.
        let undeclared = Asset(relativePath: "u.mp4", fileName: "u.mp4")
        try store.insertAsset(undeclared)
        XCTAssertNil(try store.fetchAllAssets().first { $0.id == undeclared.id }?.contentKind)
    }
}
