// PreferenceRecord.swift
// Head to Head — where a score lives, and how it is read back.
//
// 🚨 The row is what the GAME learned. `rating` is what the operator SAID.
// They are in different tables so that no future edit can make one accidentally
// stand in for the other — the same separation that keeps a source's
// description out of `Asset.notes`. Deriving stars into `rating` is an explicit,
// reviewable action (#37) and this file has no part in it.

import Foundation
import GRDB

/// Which kind of thing is being ranked. D1 runs one mechanic over both.
public enum PreferenceSubject: String, CaseIterable, Sendable, Codable {
    case actor
    case video
}

/// One contender's standing, as stored.
public struct PreferenceRecord: Codable, FetchableRecord, PersistableRecord,
                                Equatable, Sendable {
    public static let databaseTableName = "preference_score"

    public var subject: PreferenceSubject
    /// ⚠️ LOCAL to this library after v28 — a uid this library minted. Between
    /// libraries a node is its name triple (D4), so these do not travel as-is.
    public var contenderId: String
    public var score: Double
    public var comparisons: Int
    /// D6's "neither": out of the game, without being rated.
    public var retired: Bool
    public var updatedAt: Date?

    public init(subject: PreferenceSubject, contenderId: String,
                score: Double = PreferenceScore.start, comparisons: Int = 0,
                retired: Bool = false, updatedAt: Date? = nil) {
        self.subject = subject
        self.contenderId = contenderId
        self.score = score
        self.comparisons = comparisons
        self.retired = retired
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case subject
        case contenderId = "contender_id"
        case score
        case comparisons
        case retired
        case updatedAt = "updated_at"
    }

    /// The pure value the scoring engine works in.
    public var preferenceScore: PreferenceScore {
        PreferenceScore(value: score, comparisons: comparisons)
    }
}

public extension LibraryStore {

    /// Every stored standing for one subject, by contender id.
    ///
    /// ⚠️ Only what has been PLAYED. A contender with no row is unscored, and
    /// the caller must decide what that means rather than being handed a
    /// default — D9 seeds a first score from a hand-set rating, which this
    /// layer cannot know about.
    func preferenceRecords(subject: PreferenceSubject) throws -> [String: PreferenceRecord] {
        try dbQueue.read { db in
            let rows = try PreferenceRecord
                .filter(Column("subject") == subject.rawValue)
                .fetchAll(db)
            return Dictionary(rows.map { ($0.contenderId, $0) }) { first, _ in first }
        }
    }

    func preferenceRecord(subject: PreferenceSubject,
                          contenderId: String) throws -> PreferenceRecord? {
        try dbQueue.read { db in
            try PreferenceRecord
                .filter(Column("subject") == subject.rawValue
                        && Column("contender_id") == contenderId)
                .fetchOne(db)
        }
    }

    /// Writes a standing, stamping when it changed.
    ///
    /// ⚠️ `updatedAt` is set here rather than by the caller so that two writes
    /// in one comparison cannot disagree about when it happened.
    func savePreferenceRecord(_ record: PreferenceRecord, at date: Date = Date()) throws {
        try dbQueue.write { db in
            var stamped = record
            stamped.updatedAt = date
            try stamped.save(db)
        }
    }

    /// D6's "neither" — remove a contender from the game without rating them.
    ///
    /// ⭐ Keeps whatever score it had. Retiring says "this does not belong in
    /// the ranking", not "forget what we learned"; un-retiring should not
    /// restart a contender from nothing.
    func retirePreferenceContender(subject: PreferenceSubject, contenderId: String,
                                   retired: Bool = true) throws {
        try dbQueue.write { db in
            var record = try PreferenceRecord
                .filter(Column("subject") == subject.rawValue
                        && Column("contender_id") == contenderId)
                .fetchOne(db)
                ?? PreferenceRecord(subject: subject, contenderId: contenderId)
            record.retired = retired
            record.updatedAt = Date()
            try record.save(db)
        }
    }
}
