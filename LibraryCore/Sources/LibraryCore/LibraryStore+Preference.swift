// LibraryStore+Preference.swift
// Head to Head — recording a comparison, and taking it back (#33, D2 + D7).
//
// ⭐ The whole of a comparison happens inside ONE write. Reading two standings,
// computing the update and saving both are not three operations that happen to
// run in order — they are one, and a second comparison landing in the middle of
// them would read a score that is about to change and overwrite the result.
//
// 🚨 Nothing here writes `rating`. D9 says a hand-set rating SEEDS a first
// score, so this reads one when a contender has never played; the arrow points
// one way only, and #37 is the sole path back.

import Foundation
import GRDB

/// A comparison as it was actually stored, and everything undo needs.
///
/// ⚠️ Carries whether each side had a row BEFORE, which the pure
/// `PreferenceComparison` has no way to express. Undo must DELETE a row this
/// comparison created rather than writing the seeded score back — otherwise
/// taking back a contender's first-ever comparison leaves them looking played,
/// with a score they never earned and a count of zero that says otherwise.
public struct RecordedComparison: Equatable, Sendable {
    public let subject: PreferenceSubject
    public let comparison: PreferenceComparison
    public let leftExisted: Bool
    public let rightExisted: Bool
    /// Preserved so undo cannot un-retire someone as a side effect.
    public let leftRetired: Bool
    public let rightRetired: Bool
}

public extension LibraryStore {

    /// Applies one comparison to both contenders, atomically.
    ///
    /// Returns what to hand `undoComparison` if the operator mis-tapped — D7
    /// asks for one step back, and it must reverse the score change rather
    /// than merely re-show the pair.
    ///
    /// ⚠️ A contender with no standing is seeded HERE, from its hand-set
    /// rating (D9), because this is the first moment the score has to exist.
    /// Seeding earlier would write rows for contenders nobody has played, and
    /// absence is what distinguishes "never played" from "played to average".
    @discardableResult
    func recordComparison(subject: PreferenceSubject,
                          leftId: String,
                          rightId: String,
                          outcome: PreferenceOutcome,
                          at date: Date = Date()) throws -> RecordedComparison {
        guard leftId != rightId else { throw PreferenceStoreError.sameContender(leftId) }

        return try dbQueue.write { db in
            let left = try standing(for: leftId, subject: subject, in: db)
            let right = try standing(for: rightId, subject: subject, in: db)

            let updated = PreferenceScoring.apply(outcome,
                                                  left: left.score,
                                                  right: right.score)

            try save(updated.left, for: leftId, subject: subject,
                     retired: left.retired, at: date, in: db)
            try save(updated.right, for: rightId, subject: subject,
                     retired: right.retired, at: date, in: db)

            return RecordedComparison(
                subject: subject,
                comparison: PreferenceComparison(leftId: leftId, rightId: rightId,
                                                 outcome: outcome,
                                                 leftBefore: left.score,
                                                 rightBefore: right.score),
                leftExisted: left.existed, rightExisted: right.existed,
                leftRetired: left.retired, rightRetired: right.retired)
        }
    }

    /// Reverses a comparison exactly — both scores, both counts, and the rows
    /// themselves where this comparison created them.
    func undoComparison(_ recorded: RecordedComparison, at date: Date = Date()) throws {
        let restored = PreferenceScoring.undo(recorded.comparison)
        try dbQueue.write { db in
            try restore(recorded.leftExisted ? restored.left : nil,
                        for: recorded.comparison.leftId, subject: recorded.subject,
                        retired: recorded.leftRetired, at: date, in: db)
            try restore(recorded.rightExisted ? restored.right : nil,
                        for: recorded.comparison.rightId, subject: recorded.subject,
                        retired: recorded.rightRetired, at: date, in: db)
        }
    }

    // MARK: - Inside the transaction

    /// The standing to play from: the stored one, or a seed built from a
    /// hand-set rating (D9).
    private func standing(for contenderId: String, subject: PreferenceSubject,
                          in db: Database)
    throws -> (score: PreferenceScore, retired: Bool, existed: Bool) {
        if let stored = try PreferenceRecord
            .filter(Column("subject") == subject.rawValue
                    && Column("contender_id") == contenderId)
            .fetchOne(db) {
            return (stored.preferenceScore, stored.retired, true)
        }
        // ⚠️ Reads `rating`; never writes it. Ignoring an explicit statement in
        // favour of a default would be perverse (D9).
        let rating = try handRating(for: contenderId, subject: subject, in: db)
        return (PreferenceScore.seeded(byRating: rating), false, false)
    }

    private func handRating(for contenderId: String, subject: PreferenceSubject,
                            in db: Database) throws -> Int? {
        switch subject {
        case .actor:
            return try EntityProfile.fetchOne(db, key: contenderId)?.rating
        case .video:
            guard let uuid = UUID(uuidString: contenderId) else { return nil }
            return try Asset.fetchOne(db, key: uuid.uuidString)?.rating
        }
    }

    private func save(_ score: PreferenceScore, for contenderId: String,
                      subject: PreferenceSubject, retired: Bool,
                      at date: Date, in db: Database) throws {
        try PreferenceRecord(subject: subject, contenderId: contenderId,
                             score: score.value, comparisons: score.comparisons,
                             retired: retired, updatedAt: date).save(db)
    }

    /// Puts a contender back exactly as it was — including back to having no
    /// row at all.
    private func restore(_ score: PreferenceScore?, for contenderId: String,
                         subject: PreferenceSubject, retired: Bool,
                         at date: Date, in db: Database) throws {
        guard let score else {
            // ⭐ It had no standing before this comparison, so it must have
            // none after undoing it. Writing the seed back would leave a
            // contender that reads as played.
            _ = try PreferenceRecord
                .filter(Column("subject") == subject.rawValue
                        && Column("contender_id") == contenderId)
                .deleteAll(db)
            return
        }
        try save(score, for: contenderId, subject: subject,
                 retired: retired, at: date, in: db)
    }
}

public enum PreferenceStoreError: Error, Equatable {
    /// ⚠️ A contender cannot play itself. Allowed through, the two writes would
    /// race on one row and leave a score that is neither before nor after.
    case sameContender(String)
}
