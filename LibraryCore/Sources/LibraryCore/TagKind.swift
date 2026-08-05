// TagKind.swift
// What a tag DESCRIBES, and therefore what it may be attached to.
//
// The rule this exists to enforce, in the Human Operator's words: "some tags
// describe the action in a video and some tags describe the attributes of the
// performer. We shouldn't tag a video with an attribute tag — a video isn't a
// redhead, an actor is."
//
// A kind is NOT a bare label. Measured against the real library, two kinds were
// not enough — `Compilation` describes a video's form and `Amateur` describes
// its production, neither an action nor a person — so kinds are extensible. But
// an open-ended list of names would destroy the enforcement, which works only
// because a kind maps to a legal edge. So every kind declares the node type it
// attaches to, and new kinds are added as DATA with no new enforcement code.

import Foundation

public struct TagKind: Codable, Equatable, Hashable, Sendable {

    /// The node type a kind may attach to.
    ///
    /// Deliberately small and closed, unlike the kinds themselves: the set of
    /// things a tag can describe is a property of the graph's shape, not of the
    /// operator's vocabulary. Adding a case here is a model change; adding a
    /// kind is not.
    public enum Target: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case video
        case performer
    }

    /// Stable identifier, and what is persisted. Lower-case and hyphenated so
    /// it never collides with the display casing rules that apply to names.
    public let name: String

    public let target: Target

    public init(name: String, target: Target) {
        self.name = name
        self.target = target
    }
}

// MARK: - The seed set

extension TagKind {
    /// What happens in a video. The bulk of any library's vocabulary — 23 of
    /// the 30 tags measured.
    public static let action = TagKind(name: "action", target: .video)

    /// A property of the video itself rather than of anything in it: its form,
    /// its production, later its resolution or shooting style. This is the kind
    /// the real vocabulary forced into existence.
    public static let videoAttribute = TagKind(name: "video-attribute", target: .video)

    /// A property of a person. Named `performer-attribute` rather than
    /// `attribute` because with two attribute-ish kinds the bare word no longer
    /// says which node it describes.
    public static let performerAttribute = TagKind(name: "performer-attribute", target: .performer)

    /// The kinds a new library starts with. Not a closed set — an operator may
    /// add more, and nothing here assumes these are all of them.
    public static let seed: [TagKind] = [action, videoAttribute, performerAttribute]
}

// MARK: - Enforcement

extension TagKind {

    /// Whether a tag of this kind may be attached to `target`.
    ///
    /// The whole enforcement, in one line: a kind knows what it applies to, so
    /// adding a kind cannot introduce a hole here.
    public func canAttach(to target: Target) -> Bool { self.target == target }

    /// The kinds that could legally apply to `target`.
    ///
    /// ⚠️ This is the NARROWING rule, and it is why extension costs something.
    /// While there was exactly one kind per node type, the edge a source
    /// asserted *declared* the kind — a tag on a performer was an attribute, on
    /// a video an action. With two kinds targeting videos that is no longer
    /// true: the edge narrows the candidates, and only resolves the kind when
    /// the narrowing leaves exactly one.
    public static func kinds(targeting target: Target,
                             from available: [TagKind] = TagKind.seed) -> [TagKind] {
        available.filter { $0.target == target }
    }

    /// The kind to use for a tag arriving on `target` with no other signal, or
    /// nil when it cannot be decided without a human.
    ///
    /// Returns nil rather than guessing whenever several kinds could apply.
    /// A guessed kind is an edge on the wrong node, and the whole point of the
    /// taxonomy is that the graph stops being wired by accident.
    public static func inferredKind(forTagArrivingOn target: Target,
                                    from available: [TagKind] = TagKind.seed) -> TagKind? {
        let candidates = kinds(targeting: target, from: available)
        return candidates.count == 1 ? candidates.first : nil
    }
}
