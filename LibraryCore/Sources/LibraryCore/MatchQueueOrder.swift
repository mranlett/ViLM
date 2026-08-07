// MatchQueueOrder.swift
// How a queue of videos awaiting disambiguation is arranged.
//
// ⭐ Because the queue is not uniform work. A fingerprint hit with ONE candidate
// is a glance and a tap; a title search returning twelve is a genuine
// investigation. Presented in crawl order they interleave, so an operator with
// ten minutes cannot spend them on the ten that would actually close.
//
// The operator asked for exactly this: "the 1 option Fingerprint matches are
// the easiest to click through and I'd like to group those and knock them all
// out quickly."

import Foundation

/// One video waiting on a person, reduced to what decides its difficulty.
public struct MatchQueueEntry: Equatable, Sendable {
    public let route: VideoMatchRoute
    public let candidateCount: Int

    public init(route: VideoMatchRoute, candidateCount: Int) {
        self.route = route
        self.candidateCount = candidateCount
    }
}

public enum MatchQueueOrder: String, CaseIterable, Equatable, Sendable, Codable {
    /// The order the crawl found them. What the queue always did.
    case discovered
    /// ⭐ Quickest first: fewest candidates, strongest route.
    case easiest
    /// By how the video was found, so one kind can be worked through together.
    case route

    public var displayName: String {
        switch self {
        case .discovered: return "Order found"
        case .easiest:    return "Quickest first"
        case .route:      return "By how it was found"
        }
    }

    public var explanation: String {
        switch self {
        case .discovered:
            return "The order the crawl reached them."
        case .easiest:
            return "Fewest candidates first, and a fingerprint ahead of a name search — the ones that close in a glance."
        case .route:
            return "Grouped by fingerprint, cast and title, so one kind can be worked through at a time."
        }
    }
}

public extension MatchQueueOrder {

    /// How much work an entry represents. Lower is quicker.
    ///
    /// ⚠️ Candidate count dominates, and the route breaks ties — not the other
    /// way round. A title search returning ONE candidate is still one
    /// comparison; a fingerprint returning eight is still eight. Ranking by
    /// route first would put the eight ahead of the one and defeat the point.
    static func difficulty(_ entry: MatchQueueEntry) -> (Int, Int) {
        let routeRank: Int
        switch entry.route {
        case .fingerprint: routeRank = 0
        case .cast:        routeRank = 1
        case .title:       routeRank = 2
        }
        return (entry.candidateCount, routeRank)
    }

    /// Applies this order to any queue, given how to read each item.
    ///
    /// ⚠️ A STABLE sort in every mode, so items that tie keep the order the
    /// crawl found them in. Without that the list reshuffles under the operator
    /// each time one is resolved, which is disorienting in exactly the mode
    /// meant to let someone work quickly.
    func arrange<T>(_ items: [T], by entry: (T) -> MatchQueueEntry) -> [T] {
        switch self {
        case .discovered:
            return items
        case .easiest:
            return items.enumerated().sorted { a, b in
                let (x, y) = (Self.difficulty(entry(a.element)),
                              Self.difficulty(entry(b.element)))
                return x == y ? a.offset < b.offset : x < y
            }.map(\.element)
        case .route:
            return items.enumerated().sorted { a, b in
                let (x, y) = (Self.difficulty(entry(a.element)).1,
                              Self.difficulty(entry(b.element)).1)
                return x == y ? a.offset < b.offset : x < y
            }.map(\.element)
        }
    }

    /// The heading a grouped list shows above a run of entries.
    static func groupTitle(_ entry: MatchQueueEntry) -> String {
        entry.route.displayName
    }
}
