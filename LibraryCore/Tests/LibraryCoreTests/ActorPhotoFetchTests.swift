// ActorPhotoFetchTests.swift
// The policy that decides whether a recorded photo URL is DROPPED or KEPT.
//
// 🚨 These assert a data-loss boundary, not a transfer. Getting `gone` wrong in
// the permissive direction erases the only record a performer's photos had.
//
// ⚠️ All URLs invented. This repository is public.

import XCTest
@testable import LibraryCore

final class ActorPhotoFetchTests: XCTestCase {

    // MARK: - 🚨 Only an answer that can mean nothing else drops an entry

    func testOnlyNotFoundAndGoneDropTheEntry() {
        XCTAssertEqual(ActorPhotoFetch.classify(statusCode: 404, byteCount: 0), .gone)
        XCTAssertEqual(ActorPhotoFetch.classify(statusCode: 410, byteCount: 0), .gone)
    }

    /// The whole conservative rule, case by case. Each of these has a plausible
    /// reading OTHER than "the photo was deleted", so none may discard data.
    func testEverythingElseIsKept() {
        let keepers: [(Int, String)] = [
            (403, "commonly hotlink protection or a temporary block, not a deletion"),
            (429, "the source asking for patience — dropping would punish eagerness"),
            (500, "the server having a bad day"),
            (503, "maintenance"),
            (301, "a redirect this transport did not follow"),
            (400, "a bad request is a bug here, not evidence about the photo"),
        ]
        for (status, why) in keepers {
            XCTAssertEqual(ActorPhotoFetch.classify(statusCode: status, byteCount: 0),
                           .unavailable, "\(status): \(why)")
        }
    }

    func testASuccessfulAnswerWithBytesIsADownload() {
        XCTAssertEqual(ActorPhotoFetch.classify(statusCode: 200, byteCount: 1), .downloaded)
        XCTAssertEqual(ActorPhotoFetch.classify(statusCode: 204, byteCount: 4096), .downloaded)
    }

    /// ⚠️ A truncated transfer and an error page served as 200 both look like
    /// this, and neither proves the photo is missing.
    func testASuccessfulAnswerWithNoBytesIsKeptNotDropped() {
        XCTAssertEqual(ActorPhotoFetch.classify(statusCode: 200, byteCount: 0), .unavailable)
    }

    // MARK: - Unusable URLs

    func testAnUnparseableOrNonHttpUrlIsUnusable() {
        XCTAssertTrue(ActorPhotoFetch.unusable("not a url at all"))
        XCTAssertTrue(ActorPhotoFetch.unusable("ftp://example.com/a.jpg"))
        XCTAssertTrue(ActorPhotoFetch.unusable("file:///etc/passwd"))
    }

    func testHttpAndHttpsAreUsable() {
        XCTAssertFalse(ActorPhotoFetch.unusable("http://example.com/a.jpg"))
        XCTAssertFalse(ActorPhotoFetch.unusable("https://example.com/a.jpg"))
    }

    /// ⭐ The sentinel names the primary FILE, not a remote photo. It is not a
    /// fetchable URL and it is not junk to be discarded either.
    func testTheLocalPrimarySentinelIsNotUnusable() {
        XCTAssertFalse(ActorPhotoFetch.unusable(ProfileImageNaming.localPrimaryToken))
    }

    // MARK: - download

    private func destination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Fetch-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("photo.jpg")
    }

    func testASuccessfulDownloadWritesTheBytes() async throws {
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        let outcome = await ActorPhotoFetch.download("https://example.com/a.jpg", to: target) { _ in
            (Data("image".utf8), 200)
        }

        XCTAssertEqual(outcome, .downloaded)
        XCTAssertEqual(try Data(contentsOf: target), Data("image".utf8))
    }

    /// 🚨 Nothing is written on a failure. A partial file is indistinguishable
    /// from a real photo until something tries to decode it — which is what
    /// gets files deleted for being undecodable, restarting the whole cycle.
    func testAFailedDownloadWritesNothing() async {
        let target = destination()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        let outcome = await ActorPhotoFetch.download("https://example.com/a.jpg", to: target) { _ in
            (Data("<html>not found</html>".utf8), 404)
        }

        XCTAssertEqual(outcome, .gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// ⚠️ No answer at all — offline, DNS, timeout — is `unavailable` by
    /// definition. It is the commonest failure and must never drop an entry.
    func testNoAnswerAtAllIsUnavailable() async {
        let outcome = await ActorPhotoFetch.download("https://example.com/a.jpg",
                                                     to: destination()) { _ in nil }
        XCTAssertEqual(outcome, .unavailable)
    }

    /// ⚠️ A box rather than a captured `var`: the transport is `@Sendable`, and
    /// Swift 6 refuses a mutable capture across that boundary.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testAnUnusableUrlIsNeverFetched() async {
        let attempted = Flag()
        let outcome = await ActorPhotoFetch.download("htt;//broken", to: destination()) { _ in
            attempted.set()
            return (Data("x".utf8), 200)
        }
        XCTAssertEqual(outcome, .gone)
        XCTAssertFalse(attempted.isSet, "waiting cannot make an unparseable URL parse")
    }
}
