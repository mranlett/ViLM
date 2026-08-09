// SourceGapAudit.swift
// What else is this performer in, that I do not have? (#39, #40)
//
// 🚨 A different KIND of tool from everything else here. Every other audit
// describes, corrects or connects what the library CONTAINS. This one reports
// on what is missing from it — the first time the app looks outward — and that
// changes what "wrong" means. An orphan audit that misses a row costs a repair;
// this one, wrong, sends the operator looking for something already on disk.
//
// ⭐ Possible only because of the match edges. The hard part was never asking
// the source what a performer appears in; it was answering "do I already have
// this?", which used to be a fuzzy title comparison and is now an exact lookup
// on the source's own scene id.
//
// ⚠️ Pure. No network, no store — the caller supplies the source's answer and
// this library's matches. Deciding what is missing is the part worth testing
// hard, and it tests without either.

import Foundation

/// One thing the source knows about and this library does not.
public struct SourceGap: Equatable, Sendable, Identifiable {
    /// The source's own scene id.
    public let sourceId: String
    public let title: String
    public let studioName: String?
    public let releaseDate: String?

    public var id: String { sourceId }

    public init(sourceId: String, title: String,
                studioName: String? = nil, releaseDate: String? = nil) {
        self.sourceId = sourceId
        self.title = title
        self.studioName = studioName
        self.releaseDate = releaseDate
    }
}

/// A gap list, and how much of it to believe.
///
/// 🔴 D1 — the decision the feature turns on. A blanket "some of these may
/// already be in your library" is useless: a caveat covering everything says
/// nothing about anything, and gets either ignored or generalised into distrust
/// of the whole list. The over-report is measurable PER ACTOR, locally, so this
/// carries the numbers that make it precise.
public struct SourceGapReport: Equatable, Sendable {
    public let gaps: [SourceGap]
    /// Videos in this library featuring the performer.
    public let localVideos: Int
    /// ...of which carry an identity, and so could be checked against.
    public let identifiedLocalVideos: Int
    /// ⚠️ True when the source's answer was capped. A truncated list
    /// UNDER-reports, which looks like good news and is the harder failure to
    /// notice.
    public let sourceTruncated: Bool

    /// How many of the gaps might be wrong.
    ///
    /// Each unidentified local video could be any one of these scenes, so the
    /// uncertainty is bounded by the smaller of the two counts — claiming more
    /// doubt than there are gaps would be its own kind of wrong.
    public var possiblyAlreadyHeld: Int {
        min(localVideos - identifiedLocalVideos, gaps.count)
    }

    /// ⭐ Exact when every local video featuring this performer is identified:
    /// there is nothing on disk that could be hiding in the list.
    public var isExact: Bool { possiblyAlreadyHeld == 0 }

    /// 🚨 No identified videos at all means no basis for comparison. The
    /// source's whole filmography would come back as "missing", which is not an
    /// answer — it is the question restated.
    public var hasNoBasis: Bool { localVideos > 0 && identifiedLocalVideos == 0 }

    /// One line the operator can act on, rather than a warning they will learn
    /// to skip.
    public var confidence: String {
        if hasNoBasis {
            return "None of your \(localVideos) video\(localVideos == 1 ? "" : "s") with this performer "
                + "carries an identity, so there is nothing to compare against. Match some of them first."
        }
        if gaps.isEmpty {
            return sourceTruncated
                ? "Nothing new in the first \(gaps.count + identifiedLocalVideos) the source listed."
                : "Nothing the source lists is missing from your library."
        }
        let head = "\(gaps.count) scene\(gaps.count == 1 ? "" : "s") you do not have."
        if isExact {
            return head + " All \(localVideos) of your video\(localVideos == 1 ? "" : "s") "
                + "with this performer are identified, so this list is exact."
        }
        let n = possiblyAlreadyHeld
        return head + " \(n) of your \(localVideos) videos with this performer "
            + "\(n == 1 ? "is" : "are") not identified, so up to \(n) of these may already be on disk."
    }
}

public enum SourceGapAudit {

    /// What the source lists for a performer, minus what this library already
    /// has from THAT source.
    ///
    /// - Parameters:
    ///   - sourceScenes: the source's answer, in its order.
    ///   - source: which provider answered. 🚨 Load-bearing — see below.
    ///   - localMatches: every match this library holds, any source.
    ///   - localVideos / identifiedLocalVideos: this performer's footprint on
    ///     disk, for the confidence line.
    ///   - truncated: whether the source's answer hit its limit.
    public static func report(sourceScenes: [SourceGap],
                              source: String,
                              localMatches: [NodeMatch],
                              localVideos: Int,
                              identifiedLocalVideos: Int,
                              truncated: Bool) -> SourceGapReport {

        // 🚨 Scoped to the SAME source, and this is not a formality. A scene id
        // from one provider means nothing to another; they are different
        // namespaces that happen to both be strings. Comparing across them
        // would mark a scene as "already held" because an unrelated provider
        // uses the same id — a false negative that hides a real gap, and is
        // invisible because the list simply comes back shorter.
        let held = Set(localMatches.filter { $0.source == source }.map(\.sourceId))

        var seen = Set<String>()
        var gaps: [SourceGap] = []
        for scene in sourceScenes {
            guard !held.contains(scene.sourceId) else { continue }
            // ⚠️ A source that lists one scene twice must not produce two gaps.
            guard seen.insert(scene.sourceId).inserted else { continue }
            gaps.append(scene)
        }

        return SourceGapReport(gaps: gaps,
                               localVideos: localVideos,
                               identifiedLocalVideos: max(0, min(identifiedLocalVideos, localVideos)),
                               sourceTruncated: truncated)
    }
}
