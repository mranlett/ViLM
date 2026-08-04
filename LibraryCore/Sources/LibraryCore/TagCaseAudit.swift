// TagCaseAudit.swift
// Finds tags whose spelling needs repairing, and says how.
//
// Two separate problems, deliberately kept apart because one is certain and the
// other is a suggestion:
//
//   COLLISIONS  the same tag stored under two spellings that differ only by
//               case. These are the same tag by any reading — the filters
//               already compare case-insensitively — so merging them loses
//               nothing and the only question is which spelling survives.
//
//   RESPELLINGS a tag whose capitalization an external source spells
//               differently. This is a suggestion: the source is authoritative
//               about its own vocabulary and nothing else, and adopting its
//               spelling is the operator's call.
//
// Nothing here knows any actual tag. There is deliberately no built-in list of
// acronyms — a canonical spelling has to come from the data or from a source,
// never from a table compiled into the app, which would embed a vocabulary this
// code has no business carrying.

import Foundation

/// Two or more spellings of one tag, differing only by case.
public struct TagCaseCollision: Equatable, Sendable, Identifiable {
    public var id: String { key }
    /// Lowercased form the spellings share.
    public let key: String
    /// Every spelling found, most-used first.
    public let spellings: [(spelling: String, uses: Int)]

    public var totalUses: Int { spellings.reduce(0) { $0 + $1.uses } }

    /// The spelling to keep by default.
    ///
    /// Most-used wins, and a tie goes to the one carrying more capitals — where
    /// the library holds both `Scuba` and `SCUBA` equally often, the one that
    /// preserved its capitals is the one that survived a rule that used to
    /// remove them, so it is the deliberate spelling.
    public var suggestedKeeper: String {
        let best = spellings.max { a, b in
            a.uses != b.uses ? a.uses < b.uses
                             : capitals(a.spelling) < capitals(b.spelling)
        }
        return best?.spelling ?? key
    }

    public var losers: [String] { spellings.map(\.spelling).filter { $0 != suggestedKeeper } }

    private func capitals(_ value: String) -> Int {
        value.filter(\.isUppercase).count
    }

    public init(key: String, spellings: [(spelling: String, uses: Int)]) {
        self.key = key
        self.spellings = spellings
    }

    public static func == (a: TagCaseCollision, b: TagCaseCollision) -> Bool {
        a.key == b.key && a.spellings.map(\.spelling) == b.spellings.map(\.spelling)
            && a.spellings.map(\.uses) == b.spellings.map(\.uses)
    }
}

/// A tag an external source spells with different capitalization.
public struct TagRespelling: Equatable, Sendable, Identifiable {
    public var id: String { current }
    public let current: String
    public let suggested: String
    public let uses: Int
}

public enum TagCaseAudit {

    /// Tags stored under more than one capitalization.
    ///
    /// Certain rather than suggested: these are already one tag everywhere it
    /// matters, and leaving them split means a filter shows two rows for the
    /// same thing.
    public static func collisions(in tagCounts: [String: Int]) -> [TagCaseCollision] {
        var grouped: [String: [(String, Int)]] = [:]
        for (tag, uses) in tagCounts {
            grouped[tag.lowercased(), default: []].append((tag, uses))
        }
        return grouped
            .filter { $0.value.count > 1 }
            .map { key, values in
                TagCaseCollision(key: key,
                                 spellings: values
                                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                                    .map { (spelling: $0.0, uses: $0.1) })
            }
            .sorted { $0.totalUses > $1.totalUses }
    }

    /// Tags a source spells differently, ignoring anything but capitalization.
    ///
    /// A source suggesting a different WORD is not a respelling — that is a
    /// different tag, and silently adopting it would rewrite the library's
    /// vocabulary rather than repair its capitalization.
    public static func respellings(current: [String: Int],
                                   canonical: [String: String]) -> [TagRespelling] {
        current.compactMap { tag, uses -> TagRespelling? in
            guard let suggested = canonical[tag.lowercased()] else { return nil }
            guard suggested != tag else { return nil }
            guard suggested.lowercased() == tag.lowercased() else { return nil }
            return TagRespelling(current: tag, suggested: suggested, uses: uses)
        }
        .sorted { $0.uses > $1.uses }
    }

    /// Every plain tag in use, with how many videos carry it.
    public static func tagCounts(in assets: [Asset]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for asset in assets {
            for tag in asset.actions { counts[tag, default: 0] += 1 }
        }
        return counts
    }
}
