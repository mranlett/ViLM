// RelocationMoverTests.swift
// Step 3 — F4 (interruption is safe), F5 (reversibility), T23 (a failed move
// never costs a match), F2 (no orphaning).
//
// 🚨 F4 is asserted by INTERRUPTING a run at the one instant that matters — the
// window between the file landing at its new path and the catalogue learning of
// it — using the `postMoveHook` seam. A test that only checked a clean run
// would prove nothing about the property the criterion is named for, since the
// failure mode is the process dying rather than an error being returned.
//
// ⚠️ All names invented — this repository is public.

import XCTest
@testable import LibraryCore

final class RelocationMoverTests: XCTestCase {

    private var dir: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try LibraryStore(at: dir)
    }

    override func tearDownWithError() throws {
        store = nil
        LibraryStore.evictCachedConnection(forLibraryAt: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// An asset WITH a real file behind it — this suite moves files, so a
    /// record with nothing on disk would pass tests the feature cannot.
    @discardableResult
    private func addFile(_ path: String, kind: ContentKind? = .scene,
                         tags: [String] = [], released: String? = nil,
                         rating: Int? = nil, status: Asset.ReviewStatus = .unreviewed) throws -> Asset {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("video".utf8).write(to: url)
        let a = Asset(relativePath: path, fileName: (path as NSString).lastPathComponent,
                      status: status, tags: tags, rating: rating,
                      contentKind: kind, releaseDate: released)
        try store.insertAsset(a)
        return a
    }

    private func addStudio(_ name: String) throws {
        var p = try store.newEntityProfile(named: name, type: "studio")
        p.enrichmentState = .matched
        try store.saveEntityProfile(p)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
    }

    private func reloaded(_ id: UUID) throws -> Asset? {
        try store.fetchAllAssets().first { $0.id == id }
    }

    /// A one-move plan, built by hand so a test does not depend on the
    /// generator's current opinion of where a file belongs.
    private func plan(_ moves: [PlannedMove], collisions: [PathCollision] = []) -> RelocationPlan {
        RelocationPlan(moves: moves, alreadyInPlace: 0, unfilable: [], collisions: collisions)
    }

    private func move(_ asset: Asset, to target: String) -> PlannedMove {
        PlannedMove(assetId: asset.id, from: asset.relativePath, to: target, title: "Example")
    }

    // MARK: - The happy path

    func testAMoveRelocatesTheFileAndTheRecordTogether() throws {
        let asset = try addFile("old name.mp4")
        let result = try RelocationMover(store: store).run(
            plan([move(asset, to: "Example Pictures/Example Pictures - 2019-04-12.mp4")]),
            libraryURL: dir, runId: "run-1")

        XCTAssertEqual(result.moved, [asset.id])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(exists("old name.mp4"))
        XCTAssertTrue(exists("Example Pictures/Example Pictures - 2019-04-12.mp4"))
        XCTAssertEqual(try reloaded(asset.id)?.relativePath,
                       "Example Pictures/Example Pictures - 2019-04-12.mp4")
        XCTAssertEqual(try reloaded(asset.id)?.fileName,
                       "Example Pictures - 2019-04-12.mp4")
    }

    // MARK: - 🚨 F4 — interruption is safe

    /// The crash that matters: the file has moved, the catalogue has not heard.
    /// Left alone this is the worst state in the feature — a video that reads as
    /// missing. Reconciliation must finish it, not undo it.
    func testAnInterruptionAfterTheMoveIsCompletedByReconciliation() throws {
        let asset = try addFile("old name.mp4")
        var mover = RelocationMover(store: store)
        mover.postMoveHook = { _ in throw CancellationError() }

        let result = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                                   libraryURL: dir, runId: "run-1")

        // The run reports the failure rather than pretending.
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failed.count, 1)

        // Mid-crash state: file moved, record stale, journal still `planned`.
        XCTAssertTrue(exists("Filed/new name.mp4"))
        XCTAssertEqual(try reloaded(asset.id)?.relativePath, "old name.mp4")
        XCTAssertEqual(try store.relocationJournal(state: .planned).count, 1)

        let report = try store.reconcileInterruptedRelocations(libraryURL: dir)

        XCTAssertEqual(report.completed, [asset.id])
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(try reloaded(asset.id)?.relativePath, "Filed/new name.mp4")
        XCTAssertTrue(try store.relocationJournal(state: .planned).isEmpty)
    }

    /// 🚨 The invariant the whole of F4 rests on, asserted directly: when the
    /// file moves, the journal ALREADY says so. Everything else in this suite
    /// tests what reconciliation does with a `planned` row; this tests that the
    /// row is there to be found.
    ///
    /// ⭐ Asserted from inside the move itself rather than by reading the source.
    /// A scan for "is the journal call above the move call" would pass on any
    /// file containing both lines in that order, whatever they do — which is the
    /// failure mode logged on 2026-08-14.
    func testTheIntentIsRecordedBeforeTheFileMoves() throws {
        let asset = try addFile("old name.mp4")
        let library = store!
        var plannedWhenMoving = -1

        var mover = RelocationMover(store: library)
        let realMove = mover.moveFile
        mover.moveFile = { from, to in
            plannedWhenMoving = (try? library.relocationJournal(state: .planned).count) ?? -1
            try realMove(from, to)
        }
        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")

        XCTAssertEqual(plannedWhenMoving, 1,
                       "the intent must be on disk before the file is touched, or a "
                       + "crash in that window leaves a moved file nothing remembers")
    }

    /// The other side: the crash beat the move. Nothing happened, and
    /// reconciliation must not invent a relocation that never occurred.
    func testAnInterruptionBeforeTheMoveLeavesEverythingUntouched() throws {
        let asset = try addFile("old name.mp4")
        var mover = RelocationMover(store: store)
        mover.moveFile = { _, _ in throw CancellationError() }

        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")

        XCTAssertTrue(exists("old name.mp4"))
        XCTAssertFalse(exists("Filed/new name.mp4"))

        let report = try store.reconcileInterruptedRelocations(libraryURL: dir)
        XCTAssertEqual(report.abandoned, [asset.id])
        XCTAssertEqual(try reloaded(asset.id)?.relativePath, "old name.mp4")
    }

    /// 🚨 F4 stated as the criterion states it: **never half.** Asserted across
    /// a multi-file run interrupted partway, over every asset at once — the
    /// per-file tests above could both pass while the run as a whole left a mix.
    func testAfterAnInterruptedRunEveryFileIsEitherFullyMovedOrUntouched() throws {
        let assets = try (1...5).map { try addFile("video \($0).mp4") }
        let targets = assets.enumerated().map { i, a in move(a, to: "Filed/new \(i + 1).mp4") }

        var mover = RelocationMover(store: store)
        // Die on the third file, after it has moved.
        let victim = assets[2].id
        mover.postMoveHook = { id in if id == victim { throw CancellationError() } }

        _ = try mover.run(plan(targets), libraryURL: dir, runId: "run-1")
        try store.reconcileInterruptedRelocations(libraryURL: dir)

        for asset in assets {
            guard let now = try reloaded(asset.id) else {
                XCTFail("asset vanished")
                continue
            }
            let recorded: String = now.relativePath
            let original: String = asset.relativePath
            guard let planned = targets.first(where: { $0.assetId == asset.id })?.to else {
                XCTFail("no planned move")
                continue
            }
            let other: String = (recorded == original) ? planned : original

            XCTAssertTrue(exists(recorded),
                          "\(recorded): the record must point at a real file")
            XCTAssertFalse(exists(other),
                           "\(other): the file must not exist at both paths")
        }
    }

    /// ⚠️ Idempotent. A reconciliation that ran twice must not "complete" the
    /// same move again — the second pass sees no `planned` rows at all.
    func testReconciliationIsIdempotent() throws {
        let asset = try addFile("old name.mp4")
        var mover = RelocationMover(store: store)
        mover.postMoveHook = { _ in throw CancellationError() }
        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")

        let first = try store.reconcileInterruptedRelocations(libraryURL: dir)
        let second = try store.reconcileInterruptedRelocations(libraryURL: dir)

        XCTAssertEqual(first.total, 1)
        XCTAssertEqual(second.total, 0, "a second pass has nothing left to resolve")
        XCTAssertEqual(try reloaded(asset.id)?.relativePath, "Filed/new name.mp4")
    }

    /// 🚨 A file at NEITHER path is reported and the row is LEFT STANDING.
    /// Clearing it would erase the only record of where the file was supposed
    /// to go, which is the one piece of evidence a recovery would need.
    func testAFileMissingFromBothPathsIsReportedAndNotCleared() throws {
        let asset = try addFile("old name.mp4")
        var mover = RelocationMover(store: store)
        mover.postMoveHook = { _ in throw CancellationError() }
        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")

        // The file disappears entirely between the crash and the recovery.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Filed/new name.mp4"))

        let report = try store.reconcileInterruptedRelocations(libraryURL: dir)
        XCTAssertEqual(report.missing, [asset.id])
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(try store.relocationJournal(state: .planned).count, 1,
                       "the row must survive so a person can act on it")
    }

    /// A run refuses to start on top of an unresolved one.
    func testARunRefusesWhileAnEarlierRunIsUnresolved() throws {
        let asset = try addFile("old name.mp4")
        var mover = RelocationMover(store: store)
        mover.postMoveHook = { _ in throw CancellationError() }
        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Filed/new name.mp4"))

        let second = try addFile("other.mp4")
        XCTAssertThrowsError(try RelocationMover(store: store).run(
            plan([move(second, to: "Filed/other new.mp4")]),
            libraryURL: dir, runId: "run-2")) { error in
            guard case RelocationRunError.unreconciled(let missing, _) = error else {
                return XCTFail("expected unreconciled, got \(error)")
            }
            XCTAssertEqual(missing, 1)
        }
        XCTAssertTrue(exists("other.mp4"), "the refused run must not have moved anything")
    }

    // MARK: - 🚨 F5 — reversibility

    func testARunCanBePutBackExactly() throws {
        try addStudio("Example Pictures")
        let a = try addFile("first.mp4")
        let b = try addFile("nested/second.mp4")
        let mover = RelocationMover(store: store)

        _ = try mover.run(plan([move(a, to: "Filed/a new.mp4"),
                                move(b, to: "Filed/b new.mp4")]),
                          libraryURL: dir, runId: "run-1")
        XCTAssertTrue(exists("Filed/a new.mp4") && exists("Filed/b new.mp4"))

        let result = try mover.revert(runId: "run-1", libraryURL: dir)

        XCTAssertEqual(result.moved.count, 2)
        XCTAssertTrue(exists("first.mp4"), "the original layout, exactly")
        XCTAssertTrue(exists("nested/second.mp4"))
        XCTAssertFalse(exists("Filed/a new.mp4"))
        XCTAssertEqual(try reloaded(a.id)?.relativePath, "first.mp4")
        XCTAssertEqual(try reloaded(b.id)?.relativePath, "nested/second.mp4")
    }

    /// 🚨 The revert reads the JOURNAL, not the generator. If it recomputed
    /// where each file "should" be, then a run whose naming was wrong would be
    /// undone by faithfully reproducing the same wrong answer.
    ///
    /// Simulated by changing the record after the move so the generator would
    /// now propose somewhere different: the revert must ignore that entirely.
    func testARevertRestoresWhereTheFileWasNotWhereItWouldGoNow() throws {
        let asset = try addFile("original.mp4", released: "2019-04-12")
        let mover = RelocationMover(store: store)
        _ = try mover.run(plan([move(asset, to: "Filed/generated.mp4")]),
                          libraryURL: dir, runId: "run-1")

        // The world moves on: the record now says something else entirely.
        if var updated = try reloaded(asset.id) {
            updated.releaseDate = "2024-01-01"
            updated.contentKind = .film
            try store.updateAsset(updated)
        }

        _ = try mover.revert(runId: "run-1", libraryURL: dir)
        XCTAssertTrue(exists("original.mp4"))
        XCTAssertEqual(try reloaded(asset.id)?.relativePath, "original.mp4")
    }

    // MARK: - 🚨 Recovered rows, and the history they leave (2026-08-15)

    /// Reconciliation records `.recovered`, not `.done`. 🚨 Folding the two
    /// together would erase the evidence that a run was interrupted the moment
    /// it was repaired — and the operator would then see a plan with work left
    /// in it and nothing anywhere explaining why their last run stopped.
    func testReconciliationRecordsThatTheRunWasInterrupted() throws {
        let asset = try addFile("old name.mp4")
        var mover = RelocationMover(store: store)
        mover.postMoveHook = { _ in throw CancellationError() }
        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")
        try store.reconcileInterruptedRelocations(libraryURL: dir)

        XCTAssertEqual(try store.relocationJournal(state: .recovered).count, 1)
        XCTAssertTrue(try store.relocationJournal(state: .done).isEmpty)

        guard let summary = try store.lastRelocationRun() else {
            return XCTFail("no summary")
        }
        XCTAssertEqual(summary.moved, 1)
        XCTAssertEqual(summary.recovered, 1)
        XCTAssertTrue(summary.wasInterrupted,
                      "the interruption must still be reportable after the repair")
    }

    /// A clean run reports itself as clean, so the banner does not cry wolf.
    func testACleanRunIsNotReportedAsInterrupted() throws {
        let asset = try addFile("old name.mp4")
        _ = try RelocationMover(store: store).run(
            plan([move(asset, to: "Filed/new name.mp4")]), libraryURL: dir, runId: "run-1")

        guard let summary = try store.lastRelocationRun() else { return XCTFail("no summary") }
        XCTAssertEqual(summary.moved, 1)
        XCTAssertEqual(summary.recovered, 0)
        XCTAssertFalse(summary.wasInterrupted)
    }

    /// 🚨 The revert must cover recovered rows too. A file settled by
    /// reconciliation moved just as surely as one settled by its own run, and a
    /// revert reading only `.done` would strand exactly the files an interrupted
    /// run had already relocated.
    func testARevertPutsBackFilesThatReconciliationSettled() throws {
        let a = try addFile("first.mp4")
        let b = try addFile("second.mp4")
        var mover = RelocationMover(store: store)
        // Interrupt on the second file, after it has moved.
        mover.postMoveHook = { id in if id == b.id { throw CancellationError() } }
        _ = try mover.run(plan([move(a, to: "Filed/a.mp4"), move(b, to: "Filed/b.mp4")]),
                          libraryURL: dir, runId: "run-1")
        try store.reconcileInterruptedRelocations(libraryURL: dir)

        XCTAssertTrue(exists("Filed/a.mp4") && exists("Filed/b.mp4"))

        _ = try RelocationMover(store: store).revert(runId: "run-1", libraryURL: dir)

        XCTAssertTrue(exists("first.mp4"))
        XCTAssertTrue(exists("second.mp4"),
                      "the recovered file must come back too, not be left behind")
        XCTAssertEqual(try reloaded(b.id)?.relativePath, "second.mp4")
    }

    // MARK: - 🚨 #71 · reconciliation must not run against a live relocation

    /// R1 — while a run holds the token, reconciliation resolves nothing and
    /// SAYS it declined. "Did not look" must never be reported as "checked and
    /// clean": a live run's rows are `planned` too, and resolving them
    /// manufactures an interruption out of a working rename.
    func testR1ReconciliationDefersWhileARunIsInFlight() throws {
        let asset = try addFile("old name.mp4")
        let library = store!
        var reportDuringRun: ReconciliationReport?

        var mover = RelocationMover(store: library)
        // Reconcile from "another screen" at the exact moment a move is in
        // flight — the file has not landed yet and the row is `planned`.
        mover.postMoveHook = { _ in
            reportDuringRun = try? library.reconcileInterruptedRelocations(libraryURL: self.dir)
        }
        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")

        guard let reportDuringRun else { return XCTFail("no report") }
        XCTAssertTrue(reportDuringRun.deferredWhileRunning)
        XCTAssertEqual(reportDuringRun.total, 0, "it must resolve nothing")
    }

    /// R2 — the same call, once the run has finished, works normally.
    /// ⚠️ Without this the guard could be permanently on and R1 would still pass.
    func testR2ReconciliationWorksAgainOnceTheRunEnds() throws {
        let asset = try addFile("old name.mp4")
        _ = try RelocationMover(store: store).run(
            plan([move(asset, to: "Filed/new name.mp4")]), libraryURL: dir, runId: "run-1")

        let after = try store.reconcileInterruptedRelocations(libraryURL: dir)
        XCTAssertFalse(after.deferredWhileRunning, "the token must be released")
        XCTAssertFalse(RelocationActivity.isRunning)
        _ = asset
    }

    /// R3 — 🚨 the guard must not suppress the case it was built around. A
    /// genuinely interrupted run is still reconciled on the next open, because
    /// the token died with the process.
    func testR3AGenuinelyInterruptedRunIsStillReconciled() throws {
        let asset = try addFile("old name.mp4")
        var mover = RelocationMover(store: store)
        mover.postMoveHook = { _ in throw CancellationError() }
        _ = try mover.run(plan([move(asset, to: "Filed/new name.mp4")]),
                          libraryURL: dir, runId: "run-1")

        // The run has returned, so the token is released — as it would be by
        // the process dying.
        XCTAssertFalse(RelocationActivity.isRunning)
        let report = try store.reconcileInterruptedRelocations(libraryURL: dir)
        XCTAssertFalse(report.deferredWhileRunning)
        XCTAssertEqual(report.completed, [asset.id])
    }

    /// R4 — a second run refuses while one is active, rather than two movers
    /// walking one plan and reporting every already-moved file as missing.
    func testR4ASecondRunRefusesWhileOneIsActive() throws {
        let a = try addFile("first.mp4")
        let b = try addFile("second.mp4")
        let library = store!
        var secondRunError: Error?

        var mover = RelocationMover(store: library)
        mover.postMoveHook = { _ in
            do {
                _ = try RelocationMover(store: library).run(
                    self.plan([self.move(b, to: "Filed/b.mp4")]),
                    libraryURL: self.dir, runId: "run-2")
            } catch { secondRunError = error }
        }
        _ = try mover.run(plan([move(a, to: "Filed/a.mp4")]),
                          libraryURL: dir, runId: "run-1")

        XCTAssertEqual(secondRunError as? RelocationRunError, .alreadyRunning)
        XCTAssertTrue(exists("second.mp4"), "the refused run must not have moved anything")
    }

    // MARK: - Refusals

    func testAPlanWithCollisionsRefusesToRun() throws {
        let a = try addFile("one.mp4")
        let collision = PathCollision(target: "Filed/same.mp4",
                                      assetIds: [a.id, UUID()], titles: ["A", "B"])
        XCTAssertThrowsError(try RelocationMover(store: store).run(
            plan([move(a, to: "Filed/same.mp4")], collisions: [collision]),
            libraryURL: dir, runId: "run-1")) {
            XCTAssertEqual($0 as? RelocationRunError, .planCannotRun(collisions: 1))
        }
        XCTAssertTrue(exists("one.mp4"))
    }

    /// ⚠️ An occupied target is refused, never overwritten. The plan's own
    /// collision check covers two videos wanting one path; this covers a path
    /// already holding something the catalogue knows nothing about.
    func testAnOccupiedTargetIsRefusedRatherThanOverwritten() throws {
        let asset = try addFile("old name.mp4")
        let target = dir.appendingPathComponent("Filed/taken.mp4")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("someone else".utf8).write(to: target)

        let result = try RelocationMover(store: store).run(
            plan([move(asset, to: "Filed/taken.mp4")]), libraryURL: dir, runId: "run-1")

        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(try String(data: Data(contentsOf: target), encoding: .utf8),
                       "someone else", "the occupant must be untouched")
        XCTAssertTrue(exists("old name.mp4"))
    }

    /// One bad move does not abandon a good plan.
    func testOneFailureDoesNotStopTheRest() throws {
        let good = try addFile("good.mp4")
        let bad = Asset(relativePath: "ghost.mp4", fileName: "ghost.mp4", contentKind: .scene)
        try store.insertAsset(bad)   // record with no file behind it

        let result = try RelocationMover(store: store).run(
            plan([move(bad, to: "Filed/ghost.mp4"), move(good, to: "Filed/good.mp4")]),
            libraryURL: dir, runId: "run-1")

        XCTAssertEqual(result.moved, [good.id])
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(exists("Filed/good.mp4"))
    }

    // MARK: - F2 / T23 — what a move must not cost

    /// 🚨 T23. A failed move never costs a match. The record's identity is
    /// untouched by anything the filesystem does.
    func testAFailedMoveNeverCostsAMatch() throws {
        let asset = try addFile("old name.mp4")
        try store.recordMatch(NodeMatch(nodeId: asset.id.uuidString, source: "Example Source",
                                        sourceId: "abc123", method: .fingerprint),
                              isVideo: true)

        var mover = RelocationMover(store: store)
        mover.moveFile = { _, _ in throw CancellationError() }
        _ = try mover.run(plan([move(asset, to: "Filed/new.mp4")]),
                          libraryURL: dir, runId: "run-1")

        let matches = try store.videoMatches(source: "Example Source")
            .filter { $0.nodeId == asset.id.uuidString }
        XCTAssertEqual(matches.count, 1, "the match must survive a failed move")
        XCTAssertEqual(matches.first?.sourceId, "abc123")
    }

    /// F2 — no orphaning. Everything hanging off the record survives, because
    /// it hangs off the ID and never off the path.
    func testAMoveKeepsTagsRatingStatusAndDerivedFiles() throws {
        let asset = try addFile("old name.mp4", tags: ["actor:Alice Example", "tag:example"],
                                rating: 4, status: Asset.ReviewStatus.reviewed)
        // Derived files are keyed by asset id, which is what makes this free —
        // asserted rather than assumed, per F2.
        let sheet = dir.appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg")
        try FileManager.default.createDirectory(at: sheet.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("sheet".utf8).write(to: sheet)

        _ = try RelocationMover(store: store).run(
            plan([move(asset, to: "Filed/new name.mp4")]), libraryURL: dir, runId: "run-1")

        let after = try reloaded(asset.id)
        XCTAssertEqual(after?.tags, ["actor:Alice Example", "tag:Example"],
                       "tags survive the move (normalised on entry, unchanged by it)")
        XCTAssertEqual(after?.rating, 4)
        XCTAssertEqual(after?.status, Asset.ReviewStatus.reviewed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheet.path),
                      "a contact sheet is keyed by id, so a rename cannot orphan it")
    }

    /// ⭐ A relocation must never cost a re-fingerprint — the bytes did not
    /// change. Shared with `FileRenamerService` through `FrameFingerprintRekey`.
    func testTheDuplicateScanFingerprintFollowsTheFile() throws {
        let asset = try addFile("old name.mp4")
        var prints = FrameFingerprintStore(libraryURL: dir)
        prints.setHashes([1, 2, 3], relativePath: "old name.mp4", sizeBytes: 5, modified: 0)
        prints.save()

        _ = try RelocationMover(store: store).run(
            plan([move(asset, to: "Filed/new name.mp4")]), libraryURL: dir, runId: "run-1")

        let after = FrameFingerprintStore(libraryURL: dir)
        XCTAssertEqual(after.entries["Filed/new name.mp4"]?.hashes, [1, 2, 3])
        XCTAssertNil(after.entries["old name.mp4"], "the old key must not linger")
    }

    /// ⚠️ Decision 1 — rename in place. The file must be MOVED, not copied:
    /// nothing may remain at the source, because the whole reason for renaming
    /// in place is that there is no room for a second copy.
    func testTheFileIsMovedAndNotCopied() throws {
        let asset = try addFile("old name.mp4")
        _ = try RelocationMover(store: store).run(
            plan([move(asset, to: "Filed/new name.mp4")]), libraryURL: dir, runId: "run-1")

        XCTAssertFalse(exists("old name.mp4"), "a copy would leave the original behind")
        let all = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".mp4") }
        XCTAssertEqual(all, ["Filed/new name.mp4"], "exactly one copy of the video exists")
    }

    func testAnEmptyPlanIsRefusedRatherThanReportedAsSuccess() throws {
        XCTAssertThrowsError(try RelocationMover(store: store).run(
            plan([]), libraryURL: dir, runId: "run-1")) {
            XCTAssertEqual($0 as? RelocationRunError, .nothingToDo)
        }
    }
}

