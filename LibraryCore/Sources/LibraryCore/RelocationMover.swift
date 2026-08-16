// RelocationMover.swift
// Step 3 of File Naming & Metadata Storage: runs a `RelocationPlan`.
//
// 🚨 Decision 1 — rename IN PLACE. `VideoTransferService.moveVideo` is the
// obvious reuse and is the wrong tool: it copies, hash-verifies, then deletes,
// which is correct for crossing volumes and needs free space equal to the
// largest file. Disk space is the entire reason for renaming in place, so this
// uses `FileManager.moveItem` — an atomic rename, no copy, no window in which
// two copies exist.
//
// ⚠️ The failure that worried the spec is SILENT: `moveItem` across volumes
// transparently degrades to copy-then-unlink, so a cross-volume run would do
// the expensive thing and look identical while doing it. Volume identity is
// therefore checked per move rather than assumed — see `sameVolume`.
//
// ⭐ Every move is journalled before it happens (F4) and its old→new full paths
// are kept afterwards (F5). See `RelocationJournal`, which owns that reasoning.

import Foundation

/// One move that did not happen, and why.
///
/// ⚠️ A named struct rather than a tuple: it crosses a module boundary into the
/// app and appears in test assertions, and a tuple of two labelled strings
/// synthesises no `Equatable`, which pushes the failure into whatever tries to
/// compare it.
public struct RelocationFailure: Equatable, Sendable {
    public let assetId: UUID
    public let reason: String

    public init(assetId: UUID, reason: String) {
        self.assetId = assetId
        self.reason = reason
    }
}

public struct RelocationRunResult: Equatable, Sendable {
    public var runId: String
    public var moved: [UUID] = []
    /// Moves that could not be performed, with the reason.
    public var failed: [RelocationFailure] = []
    /// Reconciliation performed before this run started.
    public var reconciled: ReconciliationReport = .init()

    public var movedCount: Int { moved.count }
}

public enum RelocationRunError: Error, Equatable {
    /// 🚨 The plan says it must not run. Refused here as well as in the UI —
    /// `canRun` is a property of the plan, and a caller that forgot to consult
    /// it must not be able to move files anyway.
    case planCannotRun(collisions: Int)
    case nothingToDo
    /// An interrupted run left rows nobody can resolve automatically.
    case unreconciled(missing: Int, ambiguous: Int)
    /// 🚨 Another relocation is already in flight in this process (#71). Two
    /// movers over one plan produce spurious `sourceMissing` failures for every
    /// file the first has already moved — noise that reads as damage.
    case alreadyRunning
}

public struct RelocationMover {

    private let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - Test seams
    //
    // Default-preserving, in the style of `VideoTransferService.fileRemover`
    // and `LibraryBackupService.postAssetWriteHook`. F4 cannot be asserted
    // without a way to interrupt a run at a chosen instant, and interrupting a
    // real process mid-rename is not something a test can do.

    /// Performs the rename. Replaced in tests to simulate a failure or a crash.
    public var moveFile: (URL, URL) throws -> Void = { from, to in
        try FileManager.default.moveItem(at: from, to: to)
    }

    /// Called after the file has moved and BEFORE the catalogue learns of it —
    /// the exact window F4 exists to survive. Throwing here simulates the
    /// process dying at the one instant that matters.
    public var postMoveHook: ((UUID) throws -> Void)? = nil

    public var fileExists: (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }

    // MARK: - Running

    /// Executes a plan, one journalled move at a time.
    ///
    /// - Parameter runId: supplied by the caller so it can be recorded and
    ///   offered for revert. ⚠️ Not generated here — `Date`/`UUID` in the middle
    ///   of a run makes the result unreproducible in a test.
    @discardableResult
    public func run(_ plan: RelocationPlan, libraryURL: URL,
                    runId: String) throws -> RelocationRunResult {

        // 🚨 Claim the run token BEFORE anything else (#71). Test-and-set, so
        // two callers cannot both find it free — and held for the whole run, so
        // a plan screen opening midway reconciles nothing and says so rather
        // than resolving rows this mover is about to settle.
        guard RelocationActivity.tryBegin() else {
            throw RelocationRunError.alreadyRunning
        }
        defer { RelocationActivity.end() }

        // 🚨 Reconcile FIRST, always. Starting a fresh run on top of an
        // interrupted one would journal new intents while old ones are still
        // unresolved, and the second reconciliation could then no longer tell
        // which run a stranded file belonged to.
        //
        // ⚠️ `duringOwnRun` because the token is already held: without it this
        // mover's own reconciliation would defer to itself and never run.
        let reconciled = try store.reconcileInterruptedRelocations(
            libraryURL: libraryURL, duringOwnRun: true, fileExists: fileExists)

        guard reconciled.isClean else {
            throw RelocationRunError.unreconciled(missing: reconciled.missing.count,
                                                  ambiguous: reconciled.ambiguous.count)
        }
        guard plan.collisions.isEmpty else {
            throw RelocationRunError.planCannotRun(collisions: plan.collisions.count)
        }
        guard !plan.moves.isEmpty else { throw RelocationRunError.nothingToDo }

        var result = RelocationRunResult(runId: runId)
        result.reconciled = reconciled

        for move in plan.moves {
            do {
                try perform(move, libraryURL: libraryURL, runId: runId)
                result.moved.append(move.assetId)
            } catch {
                // ⚠️ One failure does not stop the run. Every move is
                // independent and journalled, so stopping would leave the rest
                // of a good plan unapplied for the sake of one bad file — and
                // the operator would have to work out which. Reported instead.
                result.failed.append(RelocationFailure(
                    assetId: move.assetId,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
        return result
    }

    private func perform(_ move: PlannedMove, libraryURL: URL, runId: String) throws {
        let from = libraryURL.appendingPathComponent(move.from)
        let to = libraryURL.appendingPathComponent(move.to)

        guard fileExists(from) else { throw RelocationMoveError.sourceMissing(move.from) }
        // ⚠️ Refused rather than overwritten. The plan's collision check covers
        // two videos wanting one path; this covers a path already occupied by
        // something the catalogue does not know about.
        guard !fileExists(to) else { throw RelocationMoveError.targetOccupied(move.to) }

        // 🚨 The silent-copy guard. Same volume is the precondition for
        // `moveItem` being a rename rather than a copy, and the spec asks for
        // this to be asserted because the failure only shows up as a full disk.
        guard try sameVolume(from, to.deletingLastPathComponent(), libraryURL: libraryURL) else {
            throw RelocationMoveError.crossesVolumes(move.to)
        }

        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // 1 · Intent, committed to disk before anything moves.
        let entry = try store.recordRelocationIntent(runId: runId, assetId: move.assetId,
                                                     from: move.from, to: move.to)
        guard let entryId = entry.id else { throw RelocationMoveError.journalFailed }

        // 2 · The rename.
        try moveFile(from, to)

        // The F4 window. Anything thrown here leaves a moved file and a
        // `planned` row — which is precisely the state reconciliation resolves.
        try postMoveHook?(move.assetId)

        // 3 · The catalogue and the journal, together, in one transaction.
        try store.settleRelocation(entryId, assetId: move.assetId,
                                   newPath: move.to, state: .done)

        // 4 · The sidecar, written by whatever performed the rename (S6).
        //
        // 🚨 Not a later pass, and the spec is explicit about why: a pass that
        // writes sidecars for files it did not move cannot know what they used
        // to be called, so it cannot remove the stale one. A sidecar left
        // behind under the old name is worse than none — it is metadata that
        // still looks authoritative and is now attached to nothing.
        writeSidecar(for: move.assetId, at: move.to, removing: move.from,
                     libraryURL: libraryURL)

        // 5 · Carry the duplicate-scan fingerprint across. The bytes did not
        // change, so a relocation must never cost a re-fingerprint — the same
        // rule `FileRenamerService` follows, and now shared with it.
        FrameFingerprintRekey.move(in: libraryURL, from: move.from, to: move.to)
    }

    /// Writes the `.nfo` beside a video and removes the one it left behind.
    ///
    /// ⚠️ Best-effort and never throws. A sidecar is portability, not the
    /// library — failing to write one must not fail a move that has already
    /// happened, and must certainly not undo it. Reported by its absence, which
    /// a later pass can correct because the file is by then where it belongs.
    ///
    /// 🚨 The OLD sidecar goes even when no new one is written. Personal and
    /// undeclared content writes none (D4), and if such a video is ever moved,
    /// leaving the previous document beside its old path would strand exactly
    /// the plaintext the rule exists to keep off the disk.
    private func writeSidecar(for assetId: UUID, at newPath: String,
                              removing oldPath: String, libraryURL: URL) {
        let stale = libraryURL.appendingPathComponent(MetadataSidecar.path(forVideo: oldPath))
        try? FileManager.default.removeItem(at: stale)

        guard let store = try? LibraryStore(at: libraryURL),
              let asset = try? store.fetchAllAssets().first(where: { $0.id == assetId })
        else { return }

        let profiles = (try? store.fetchAllEntityProfiles()).map(EntityProfileIndex.init)
        let cast = asset.actors.map { name in
            SidecarPerformer(name: name, thumbURL: profiles?[actor: name]?.photoUrl)
        }
        let stem = (asset.fileName as NSString).deletingPathExtension
        guard let document = MetadataSidecar.document(
            for: asset, cast: cast, studio: asset.studios.first, fallbackTitle: stem)
        else { return }

        let target = libraryURL.appendingPathComponent(MetadataSidecar.path(forVideo: newPath))
        try? document.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Whether both ends sit on one volume.
    ///
    /// ⭐ Within a single library this is true by construction, so the check is
    /// expected to pass every time. It exists because the case where it does
    /// not — a library root spanning a mount point — is invisible: `moveItem`
    /// would quietly copy several terabytes rather than refuse.
    ///
    /// ⚠️ The destination directory may not exist yet, so the nearest existing
    /// ancestor is measured instead. Falling back to the library root is safe:
    /// a directory this run is about to create is on whatever volume its parent
    /// is on.
    private func sameVolume(_ from: URL, _ toDirectory: URL, libraryURL: URL) throws -> Bool {
        func volume(of url: URL) -> String? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path),
                  probe.path.count > libraryURL.path.count {
                probe = probe.deletingLastPathComponent()
            }
            let values = try? probe.resourceValues(forKeys: [.volumeIdentifierKey])
            guard let identifier = values?.volumeIdentifier else { return nil }
            return String(describing: identifier)
        }
        guard let a = volume(of: from), let b = volume(of: toDirectory) else {
            // Undeterminable. Treated as SAME rather than refusing, because the
            // library root is one directory tree and refusing every move on an
            // unreadable attribute would make the feature unusable on a volume
            // type that simply does not report an identifier.
            return true
        }
        return a == b
    }

    // MARK: - N2 — relocation rides matching

    /// What became of a single video offered for relocation at match time.
    public enum MatchRelocation: Equatable, Sendable {
        /// Moved. Carries the new path so the caller can keep its own copy of
        /// the record in step — 🚨 without this the caller writes the asset it
        /// was holding and puts the OLD path straight back over the new one.
        case moved(to: String)
        /// The grammar cannot file it yet — undeclared, or a field missing.
        /// Not a failure: the file stays where it is and stays usable (F10).
        case notFilable(NamingSkip)
        /// Already where it belongs.
        case alreadyInPlace
        /// Tried and could not. ⚠️ Reported, never thrown — see below.
        case failed(String)
    }

    /// Relocates ONE video, immediately after its match was confirmed (N2).
    ///
    /// ⭐ Per the Epic's D8, this is the moment a video's metadata is at its
    /// best and an operator is present — so resumability is free, a partly
    /// migrated library is the normal state rather than an error, and the blast
    /// radius of a mistake is one file instead of the library.
    ///
    /// 🚨 **Never throws for a filesystem problem.** T23 says a failed move must
    /// never cost a match, and the match is already committed by the time this
    /// runs. Throwing here would tempt a caller into rolling back the very
    /// thing that must survive; a `.failed` case cannot be mistaken for a
    /// reason to undo the match.
    ///
    /// ⚠️ Deliberately NOT called from unattended batch runs. N2's justification
    /// is that an operator is present to see what happened — which is true of a
    /// confirmation and false of a hundred videos matched overnight. Those stay
    /// with the whole-library plan, where the moves are read before they run.
    public func relocateAfterMatch(assetId: UUID, libraryURL: URL,
                                   runId: String) -> MatchRelocation {
        // 🚨 Same token as a bulk run (#71). Without it this path left
        // `isRunning` false while a move was in flight, so the plan screen
        // opening at that instant would reconcile a row this mover was about to
        // settle. `run` was guarded and the other two entry points were not —
        // the guard is only worth anything if every writer takes it.
        guard RelocationActivity.tryBegin() else { return .failed("A rename is already running.") }
        defer { RelocationActivity.end() }
        do {
            // ⚠️ Reconcile first, even here. An earlier run interrupted after
            // moving THIS asset leaves the catalogue naming the old path — so
            // the plan would propose moving a file that is no longer there and
            // the operator would be told their video is missing when it is
            // safely at its destination. Cheap: a query over `planned` rows,
            // which is normally empty.
            // ⚠️ The INJECTED `fileExists`, same as `run` passes. Omitting it
            // let a test's filesystem double be bypassed on this one path, so
            // the seam would silently read the real disk.
            try store.reconcileInterruptedRelocations(libraryURL: libraryURL,
                                                      duringOwnRun: true,
                                                      fileExists: fileExists)
            let plan = try store.relocationPlan(limitedTo: [assetId])

            if let skip = plan.unfilable.first(where: { $0.assetId == assetId }) {
                return .notFilable(skip.skip)
            }
            guard let move = plan.moves.first(where: { $0.assetId == assetId }) else {
                return .alreadyInPlace
            }
            try perform(move, libraryURL: libraryURL, runId: runId)
            return .moved(to: move.to)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: - F5 — putting it back

    /// Reverses a completed run, newest move first.
    ///
    /// 🚨 Driven by the JOURNAL, not by recomputing the plan. Regenerating
    /// where each file "should" be would restore where the generator thinks it
    /// belongs today, which is not the same as where it actually was — and if
    /// the generator is what went wrong, recomputing would faithfully reproduce
    /// the damage.
    @discardableResult
    public func revert(runId: String, libraryURL: URL) throws -> RelocationRunResult {
        // 🚨 And here. A revert moves files, so reconciliation must not run
        // against it either.
        guard RelocationActivity.tryBegin() else { throw RelocationRunError.alreadyRunning }
        defer { RelocationActivity.end() }

        var result = RelocationRunResult(runId: runId)

        // Reverse order, so a file moved into a directory another move created
        // leaves before the directory is considered empty.
        // ⚠️ BOTH settled-as-moved states. A file recovered by reconciliation
        // moved just as surely as one settled by its own run, and a revert that
        // read only `.done` would leave exactly the files an interrupted run
        // had already relocated — the ones most likely to need putting back.
        let settled = try (store.relocationJournal(runId: runId, state: .done)
                           + store.relocationJournal(runId: runId, state: .recovered))
            .sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        for entry in settled.reversed() {
            guard let entryId = entry.id, let assetId = UUID(uuidString: entry.assetId) else {
                continue
            }
            let current = libraryURL.appendingPathComponent(entry.toPath)
            let original = libraryURL.appendingPathComponent(entry.fromPath)
            do {
                guard fileExists(current) else {
                    throw RelocationMoveError.sourceMissing(entry.toPath)
                }
                guard !fileExists(original) else {
                    throw RelocationMoveError.targetOccupied(entry.fromPath)
                }
                try FileManager.default.createDirectory(
                    at: original.deletingLastPathComponent(), withIntermediateDirectories: true)

                // 🚨 Write-ahead, exactly as `perform` does — a revert is a
                // relocation and needs the same protection.
                //
                // This moved the file FIRST and settled afterwards, so a throw
                // from `settleRelocation` (or the process dying) left the file
                // back at its original path with the catalogue still naming the
                // new one, and no `planned` row for reconciliation to find. The
                // file was simply orphaned. Found by the auditor; it is the same
                // asymmetry the journal was built to remove, reintroduced in the
                // one path that did not go through `perform`.
                //
                // ⚠️ Its own run id, so the reverse rows are not themselves
                // picked up as movable work by a later revert of the SAME run.
                let back = try store.recordRelocationIntent(
                    runId: "revert-\(runId)", assetId: assetId,
                    from: entry.toPath, to: entry.fromPath, kind: .revert)
                guard let backId = back.id else { throw RelocationMoveError.journalFailed }

                try moveFile(current, original)

                // The reverse row settles as `.reverted` rather than `.done`, so
                // "your last run" never reports an undo as a rename.
                try store.settleRelocation(backId, assetId: assetId,
                                           newPath: entry.fromPath, state: .reverted)
                try store.settleRelocationRowOnly(entryId, state: .reverted)
                // ⚠️ The sidecar goes back too. Undoing a move and leaving the
                // document beside the new path would strand it next to nothing.
                writeSidecar(for: assetId, at: entry.fromPath, removing: entry.toPath,
                             libraryURL: libraryURL)
                FrameFingerprintRekey.move(in: libraryURL,
                                           from: entry.toPath, to: entry.fromPath)
                result.moved.append(assetId)
            } catch {
                result.failed.append(RelocationFailure(assetId: assetId,
                                                       reason: "\(error)"))
            }
        }
        return result
    }
}

public enum RelocationMoveError: Error, Equatable, LocalizedError {
    case sourceMissing(String)
    case targetOccupied(String)
    case crossesVolumes(String)
    case journalFailed

    public var errorDescription: String? {
        switch self {
        case let .sourceMissing(path):
            return "The file is no longer at \(path)."
        case let .targetOccupied(path):
            return "Something is already at \(path), and it was not overwritten."
        case let .crossesVolumes(path):
            return "\(path) is on a different volume, which would mean copying the "
                 + "whole file rather than renaming it. Refused."
        case .journalFailed:
            return "The move could not be recorded, so it was not attempted."
        }
    }
}

/// Carrying a duplicate-scan fingerprint from one path to another.
///
/// ⭐ Extracted so the mover and `FileRenamerService` share one expression of
/// the rule. Two copies of "a rename must not cost a re-fingerprint" is exactly
/// the drift that `ActorCredits` was created to end, and the cost of getting it
/// wrong here is a silent full re-scan of a 2,000-file library.
public enum FrameFingerprintRekey {
    public static func move(in libraryURL: URL, from: String, to: String) {
        var prints = FrameFingerprintStore(libraryURL: libraryURL)
        guard let entry = prints.entries[from] else { return }
        prints.setHashes(entry.hashes, relativePath: to,
                         sizeBytes: entry.sizeBytes, modified: entry.modified)
        prints.removeEntry(relativePath: from)
        prints.save()
    }
}
