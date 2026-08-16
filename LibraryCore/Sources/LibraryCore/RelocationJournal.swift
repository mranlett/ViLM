// RelocationJournal.swift
// The write-ahead record that makes a relocation interruptible (F4) and
// reversible (F5).
//
// 🚨 The ordering is the whole design: the intent is committed to the database
// BEFORE the file moves. Any other order has a window in which a file has moved
// and nothing on disk remembers that it was supposed to. `FileRenamerService`
// rolls back when the database write *throws*, which is a different property —
// a `do/catch` cannot run if the process is killed.
//
// ⭐ So a crash never leaves an unknown state, only an unfinished one. Every
// `planned` row is answerable by looking at the two paths it names, and
// `reconcile` turns each into "the move happened, finish the bookkeeping" or
// "the move never happened, abandon it". That is exactly F4's promise: fully
// relocated and consistent, or untouched. Never half.

import Foundation
import GRDB

/// One recorded move, and how far it got.
public struct RelocationJournalEntry: Codable, FetchableRecord, PersistableRecord,
                                      Equatable, Sendable {
    public static let databaseTableName = "relocation_journal"

    public enum State: String, Codable, Sendable {
        /// Written before the file is touched. A row left in this state is an
        /// interrupted run, not a failed one.
        case planned
        /// The file is at `toPath` and the asset row agrees.
        case done
        /// Moved, but settled by RECONCILIATION rather than by the run itself —
        /// i.e. the run was interrupted after this file moved.
        ///
        /// 🚨 A separate state, not folded into `done`, because otherwise the
        /// evidence that a run was interrupted disappears the moment it is
        /// repaired. The operator then sees a plan with work left in it and
        /// nothing anywhere saying their last run stopped early — which is
        /// exactly the complaint this state exists to answer.
        case recovered
        /// The file never moved. Recorded rather than deleted so an interrupted
        /// run leaves evidence it happened at all.
        case abandoned
        /// Put back by an explicit revert (F5).
        case reverted
    }

    public var id: Int64?
    public var runId: String
    public var assetId: String
    public var fromPath: String
    public var toPath: String
    public var state: String
    public var createdAt: Date
    public var settledAt: Date?

    public var stateValue: State { State(rawValue: state) ?? .planned }

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case assetId = "asset_id"
        case fromPath = "from_path"
        case toPath = "to_path"
        case state
        case createdAt = "created_at"
        case settledAt = "settled_at"
    }

    public init(id: Int64? = nil, runId: String, assetId: String,
                fromPath: String, toPath: String,
                state: State = .planned,
                createdAt: Date = Date(), settledAt: Date? = nil) {
        self.id = id
        self.runId = runId
        self.assetId = assetId
        self.fromPath = fromPath
        self.toPath = toPath
        self.state = state.rawValue
        self.createdAt = createdAt
        self.settledAt = settledAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// What an interrupted move turned out to be, once the disk was consulted.
public enum ReconciledOutcome: Equatable, Sendable {
    /// The file had already moved; the catalogue row has now caught up.
    case completed
    /// The file never moved; the row was abandoned and nothing changed.
    case abandoned
    /// 🚨 The file is at NEITHER path. Reported, never guessed at.
    case fileMissing
    /// The file is at BOTH paths. Only reachable through a non-atomic move, so
    /// it should not occur — reported rather than resolved, because choosing
    /// one to delete is a decision about data.
    case ambiguous
}

/// Whether a relocation run is in flight in THIS process (#71).
///
/// 🚨 A `planned` journal row means the run died **or** the run is still going,
/// and nothing in the data separates them. Reconciliation resolving rows that a
/// live mover is about to settle produces a library that reports interruptions
/// which never happened — and a phantom interruption has already cost an
/// evening of investigation once.
///
/// ⭐ IN-PROCESS is the right scope, and deliberately not persisted. If the app
/// dies the flag dies with it, which is exactly the moment reconciliation
/// *should* run. A stored "a run is active" marker would itself become stale
/// state needing recovery — the very problem it was introduced to solve.
public enum RelocationActivity {
    private static let lock = NSLock()
    /// ⚠️ `nonisolated(unsafe)` because the synchronisation is the `NSLock`
    /// above, hand-rolled rather than actor-provided. Every read and write below
    /// takes it; nothing touches this outside those four accessors.
    nonisolated(unsafe) private static var active = false

    public static var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Claims the run token, or fails if one is already held.
    ///
    /// ⚠️ Test-and-set under one lock rather than `isRunning` then `begin()`.
    /// Two callers can both read `false` between those two statements, which is
    /// a race about a race.
    static func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active { return false }
        active = true
        return true
    }

    static func end() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }
}

/// What the most recent run did, read back from the journal.
///
/// ⭐ Exists because a run that was interrupted returns no result to report —
/// the process went away — and that is exactly the run the operator most needs
/// told about. The journal is the only witness.
public struct RelocationRunSummary: Equatable, Sendable {
    public let runId: String
    /// Files that ended up at their new path, however they got settled.
    public let moved: Int
    /// Of those, how many were settled by reconciliation — i.e. the run was
    /// interrupted after they moved.
    public let recovered: Int
    /// Rows still unresolved. Nonzero means a person is needed.
    public let unresolved: Int
    public let at: Date?

    /// 🚨 Whether that run stopped early. `recovered > 0` is the durable proof:
    /// a file only reaches that state because the run died between moving it
    /// and recording the move.
    public var wasInterrupted: Bool { recovered > 0 || unresolved > 0 }

    public init(runId: String, moved: Int, recovered: Int, unresolved: Int, at: Date?) {
        self.runId = runId
        self.moved = moved
        self.recovered = recovered
        self.unresolved = unresolved
        self.at = at
    }
}

public struct ReconciliationReport: Equatable, Sendable {
    public var completed: [UUID] = []
    public var abandoned: [UUID] = []
    public var missing: [UUID] = []
    public var ambiguous: [UUID] = []

    /// 🚨 Set when reconciliation DECLINED to run because a relocation was in
    /// flight (#71). Distinct from "nothing to resolve": the difference is
    /// between *checked and clean* and *did not look*, and reporting the second
    /// as the first is how a screen states a fact it has not established.
    public var deferredWhileRunning = false

    public var isClean: Bool { missing.isEmpty && ambiguous.isEmpty }
    public var total: Int {
        completed.count + abandoned.count + missing.count + ambiguous.count
    }
}

public extension LibraryStore {

    // MARK: - Writing

    /// Commits the intent to move, and returns the row that records it.
    ///
    /// 🚨 Its own transaction, deliberately NOT batched with the others. The
    /// point is that this reaches the disk before the file does; grouping a
    /// run's intents into one transaction would put every file at risk of the
    /// window this exists to close.
    @discardableResult
    func recordRelocationIntent(runId: String, assetId: UUID,
                                from: String, to: String) throws -> RelocationJournalEntry {
        var entry = RelocationJournalEntry(runId: runId, assetId: assetId.uuidString,
                                           fromPath: from, toPath: to)
        try dbQueue.write { db in
            try entry.insert(db)
            // ⚠️ Read the row id explicitly rather than relying on `didInsert`
            // populating it. Without this the id came back `nil`, every move
            // was refused as "could not be recorded" — and the refusal was
            // correct: a move that is not journalled must not happen, so the
            // bug showed up as the feature safely doing nothing rather than as
            // a crash.
            if entry.id == nil { entry.id = db.lastInsertedRowID }
        }
        return entry
    }

    /// Marks a journalled move settled, in the SAME transaction as the asset's
    /// new path.
    ///
    /// ⚠️ One transaction is what keeps the two facts from disagreeing. Written
    /// separately, a crash between them produces a file that has moved, a row
    /// that knows, and a journal that still says `planned` — which the next
    /// reconciliation would then "complete" a second time.
    func settleRelocation(_ entryId: Int64, assetId: UUID, newPath: String,
                          state: RelocationJournalEntry.State) throws {
        try dbQueue.write { db in
            if var asset = try Asset.fetchOne(db, key: assetId.uuidString) {
                asset.relativePath = newPath
                asset.fileName = (newPath as NSString).lastPathComponent
                try asset.update(db)
            }
            try db.execute(
                sql: "UPDATE relocation_journal SET state = ?, settled_at = ? WHERE id = ?",
                arguments: [state.rawValue, Date(), entryId])
        }
    }

    /// Settles a journal row without touching the asset — for an abandoned
    /// move, where the file never left its original path.
    func settleRelocationRowOnly(_ entryId: Int64,
                                 state: RelocationJournalEntry.State) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE relocation_journal SET state = ?, settled_at = ? WHERE id = ?",
                arguments: [state.rawValue, Date(), entryId])
        }
    }

    // MARK: - Reading

    func relocationJournal(runId: String? = nil,
                           state: RelocationJournalEntry.State? = nil)
    throws -> [RelocationJournalEntry] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM relocation_journal"
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            if let runId { clauses.append("run_id = ?"); args.append(runId) }
            if let state { clauses.append("state = ?"); args.append(state.rawValue) }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY id"
            return try RelocationJournalEntry.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// The most recent run that moved anything, for offering a revert.
    func lastCompletedRelocationRunId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT run_id FROM relocation_journal
                 WHERE state IN (?, ?) ORDER BY id DESC LIMIT 1
                """, arguments: [RelocationJournalEntry.State.done.rawValue,
                                  RelocationJournalEntry.State.recovered.rawValue])
        }
    }

    /// What the most recent run actually did, kept so the plan screen can say
    /// so long after the run itself.
    ///
    /// ⚠️ Reported from the JOURNAL, not from a result held in memory. A run
    /// that was interrupted never returns a result at all — which is precisely
    /// the case the operator most needs told about.
    func lastRelocationRun() throws -> RelocationRunSummary? {
        guard let runId = try lastCompletedRelocationRunId() else { return nil }
        let rows = try relocationJournal(runId: runId)
        guard !rows.isEmpty else { return nil }
        let moved = rows.filter { $0.stateValue == .done || $0.stateValue == .recovered }
        return RelocationRunSummary(
            runId: runId,
            moved: moved.count,
            recovered: rows.filter { $0.stateValue == .recovered }.count,
            unresolved: rows.filter { $0.stateValue == .planned }.count,
            at: rows.compactMap(\.settledAt).max() ?? rows.map(\.createdAt).max())
    }

    // MARK: - F4 — reconciling an interrupted run

    /// Resolves every `planned` row by asking the filesystem what actually
    /// happened, and brings the catalogue into agreement with it.
    ///
    /// 🚨 Consults the DISK, never a guess. A `planned` row means only "we were
    /// about to move this"; whether we did is a question the two paths answer
    /// definitively, and the answer differs per row within a single interrupted
    /// run — the file being written at the moment of the crash is in a
    /// different state from the ones queued behind it.
    ///
    /// ⚠️ Runs before any new relocation and is safe to call at any time. It is
    /// idempotent: a second call finds no `planned` rows and does nothing.
    @discardableResult
    /// - Parameter duringOwnRun: set only by the mover, which holds the run
    ///   token and is therefore the one caller for whom live rows are its own.
    ///   ⚠️ Every other caller must leave this false, or the guard is decorative.
    func reconcileInterruptedRelocations(libraryURL: URL,
                                         duringOwnRun: Bool = false,
                                         fileExists: (URL) -> Bool = {
                                             FileManager.default.fileExists(atPath: $0.path)
                                         }) throws -> ReconciliationReport {
        var report = ReconciliationReport()

        // 🚨 #71. A live run's rows are `planned` too, and resolving them would
        // manufacture an interruption out of a working rename.
        guard duringOwnRun || !RelocationActivity.isRunning else {
            report.deferredWhileRunning = true
            return report
        }

        for entry in try relocationJournal(state: .planned) {
            guard let entryId = entry.id, let assetId = UUID(uuidString: entry.assetId) else {
                continue
            }
            let atSource = fileExists(libraryURL.appendingPathComponent(entry.fromPath))
            let atTarget = fileExists(libraryURL.appendingPathComponent(entry.toPath))

            switch (atSource, atTarget) {
            case (false, true):
                // The move landed and the bookkeeping did not. Finish it.
                try settleRelocation(entryId, assetId: assetId,
                                     newPath: entry.toPath, state: .recovered)
                report.completed.append(assetId)

            case (true, false):
                // The crash beat the move. Nothing happened, and nothing should.
                try settleRelocationRowOnly(entryId, state: .abandoned)
                report.abandoned.append(assetId)

            case (false, false):
                // 🚨 Left `planned` ON PURPOSE. Neither path holds the file, so
                // this needs a person — and clearing the row would erase the
                // only record of where the file was supposed to be, which is
                // the one piece of evidence a recovery would need.
                report.missing.append(assetId)

            case (true, true):
                // Both. An atomic rename cannot produce this; a half-finished
                // copy can. Deleting either one is a decision about data, so it
                // is reported and the row is left standing.
                report.ambiguous.append(assetId)
            }
        }
        return report
    }
}
