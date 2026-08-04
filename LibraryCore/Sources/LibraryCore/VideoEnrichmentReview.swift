// VideoEnrichmentReview.swift
// Turns a plugin's proposal for one video into rows a person can accept or
// reject, and applies the accepted ones.
//
// Same three-way split the actor side uses, for the same reason: a source is a
// suggestion, not an authority.
//
//   FILL       the library has nothing here — safe, offered pre-ticked
//   CONFLICT   both hold a real value and they differ — never applied unless
//              the operator explicitly says so
//   UNCHANGED  they already agree — not shown at all
//
// Performers and studio are additive tags rather than replacements. A match
// that knows two of the three people in a video must not be able to delete the
// third, so accepting it adds names and never removes them.

import Foundation

public struct VideoFieldChange: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case fill
        case conflict
    }

    public var id: String { field }
    /// Stable key used by the UI to track which rows are ticked.
    public let field: String
    public let label: String
    public let kind: Kind
    /// What the library holds now, for display. Empty when it holds nothing.
    public let current: String
    /// What the source suggests.
    public let proposed: String
    public let sourceNote: String?

    public init(field: String, label: String, kind: Kind,
                current: String, proposed: String, sourceNote: String? = nil) {
        self.field = field
        self.label = label
        self.kind = kind
        self.current = current
        self.proposed = proposed
        self.sourceNote = sourceNote
    }
}

/// One tag a source suggests, and whether this library already uses it.
public struct VideoTagOption: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Already in the library's vocabulary, so ticked by default.
    public let isKnown: Bool

    public init(name: String, isKnown: Bool) {
        self.name = name
        self.isKnown = isKnown
    }
}

public enum VideoEnrichmentReview {

    public enum Field {
        public static let seriesTitle = "seriesTitle"
        public static let seasonNumber = "seasonNumber"
        public static let episodeNumber = "episodeNumber"
        public static let episodeTitle = "episodeTitle"
        public static let releaseDate = "releaseDate"
        public static let studio = "studio"
        public static let performers = "performers"
    }

    /// Every row worth showing, fills first.
    ///
    /// Fields where the two already agree are omitted entirely — a review sheet
    /// listing a dozen "no change" rows buries the handful that matter.
    /// - Parameter knownTags: the tag vocabulary this library already uses.
    ///   When non-empty, only tags already in it are proposed.
    ///
    ///   Sources tag far more finely than a personal library does — one real
    ///   scene record carried seventy. Accepting that on a single video buries
    ///   the vocabulary the operator built and makes the tag list useless for
    ///   filtering. Restricting to terms already in use turns the source into
    ///   something that fills in tags you meant to apply, rather than one that
    ///   imposes its own taxonomy. Pass an empty set to accept everything.
    public static func changes(for asset: Asset,
                               proposal: VideoMetadataProposal,
                               knownTags: Set<String> = []) -> [VideoFieldChange] {
        var rows: [VideoFieldChange] = []

        func scalar(_ field: String, _ label: String,
                    current: String?, proposed: String?, note: String?) {
            guard let proposed, !proposed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let existing = (current ?? "").trimmingCharacters(in: .whitespaces)
            if existing.isEmpty {
                rows.append(.init(field: field, label: label, kind: .fill,
                                  current: "", proposed: proposed, sourceNote: note))
            } else if existing.caseInsensitiveCompare(proposed) != .orderedSame {
                rows.append(.init(field: field, label: label, kind: .conflict,
                                  current: existing, proposed: proposed, sourceNote: note))
            }
        }

        scalar(Field.seriesTitle, "Series", current: asset.videoName,
               proposed: proposal.seriesTitle.value, note: proposal.seriesTitle.sourceNote)
        scalar(Field.seasonNumber, "Season / Volume", current: asset.seasonNumber.map(String.init),
               proposed: proposal.seasonNumber.value.map(String.init), note: proposal.seasonNumber.sourceNote)
        scalar(Field.episodeNumber, "Episode Number", current: asset.episodeNumber.map(String.init),
               proposed: proposal.episodeNumber.value.map(String.init), note: proposal.episodeNumber.sourceNote)
        scalar(Field.episodeTitle, "Episode Title", current: asset.episode,
               proposed: proposal.episodeTitle.value ?? proposal.title.value,
               note: proposal.episodeTitle.sourceNote ?? proposal.title.sourceNote)
        scalar(Field.releaseDate, "Release Date", current: asset.releaseDate,
               proposed: proposal.releaseDate.value, note: proposal.releaseDate.sourceNote)

        // Studio is a tag, so "already has it" means the tag is present.
        if let studio = proposal.studio.value, !studio.isEmpty {
            let held = asset.studios.contains { $0.caseInsensitiveCompare(studio) == .orderedSame }
            if !held {
                rows.append(.init(field: Field.studio, label: "Studio", kind: .fill,
                                  current: asset.studios.joined(separator: ", "),
                                  proposed: studio, sourceNote: proposal.studio.sourceNote))
            }
        }

        // Performers add; they never replace. Only the genuinely new ones are
        // offered, so the row says what would actually change.
        if let performers = proposal.actors.value {
            let held = Set(asset.actors.map { $0.lowercased() })
            let additions = performers.filter { !held.contains($0.lowercased()) }
            if !additions.isEmpty {
                rows.append(.init(field: Field.performers, label: "Performers", kind: .fill,
                                  current: asset.actors.joined(separator: ", "),
                                  proposed: additions.joined(separator: ", "),
                                  sourceNote: proposal.actors.sourceNote))
            }
        }

        // Fills lead: they are the safe ones and most reviews accept them all.
        return rows.sorted { a, b in
            a.kind == b.kind ? false : a.kind == .fill
        }
    }

    /// The asset as it would be with `accepting` applied. Pure — the caller
    /// saves it.
    ///
    /// A field not named in `accepting` is left exactly as it was, which is what
    /// makes an untouched conflict harmless.
    /// Every tag the source offers that this video does not already carry,
    /// each marked with whether the library already uses it.
    ///
    /// All of them are offered rather than filtered away: a source knows things
    /// the library has no word for yet, and hiding those makes the feature
    /// quietly lossy. What differs is the DEFAULT — see `defaultSelection`.
    /// Sorted known-first so the ones that will be applied sit together at the
    /// top instead of scattered through a list of seventy.
    public static func tagOptions(for asset: Asset,
                                  proposal: VideoMetadataProposal,
                                  knownTags: Set<String>) -> [VideoTagOption] {
        guard let tags = proposal.tags.value else { return [] }
        let held = Set(asset.actions.map { $0.lowercased() })
        let vocabulary = Set(knownTags.map { $0.lowercased() })
        let options = tags
            .filter { !held.contains($0.lowercased()) }
            .map { VideoTagOption(name: $0, isKnown: vocabulary.contains($0.lowercased())) }
        return options.sorted { a, b in
            a.isKnown == b.isKnown ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                                   : a.isKnown
        }
    }

    /// Ticked to begin with: only the tags this library already uses.
    ///
    /// A source tags far more finely than a person does — one real record
    /// carried seventy on a single video. Defaulting those on would bury a
    /// hand-built vocabulary under someone else's taxonomy on the first
    /// accept, and undoing it means editing seventy tags off by hand. Ones the
    /// operator already uses are a different matter: applying those is filling
    /// in a tag they meant to add.
    public static func defaultSelection(_ options: [VideoTagOption]) -> Set<String> {
        Set(options.filter(\.isKnown).map(\.name))
    }

    /// - Parameter acceptedTags: the exact tag names to add, chosen
    ///   individually. Nothing outside this set is applied, so a tag the
    ///   operator did not tick can never arrive by another route.
    public static func merged(asset: Asset,
                              proposal: VideoMetadataProposal,
                              accepting: Set<String>,
                              acceptedTags: Set<String> = []) -> Asset {
        var merged = asset

        if accepting.contains(Field.seriesTitle), let v = proposal.seriesTitle.value { merged.videoName = v }
        if accepting.contains(Field.seasonNumber), let v = proposal.seasonNumber.value { merged.seasonNumber = v }
        if accepting.contains(Field.episodeNumber), let v = proposal.episodeNumber.value { merged.episodeNumber = v }
        if accepting.contains(Field.episodeTitle) {
            if let v = proposal.episodeTitle.value ?? proposal.title.value { merged.episode = v }
        }
        if accepting.contains(Field.releaseDate), let v = proposal.releaseDate.value { merged.releaseDate = v }

        var tags = merged.tags
        func addTag(_ raw: String) {
            let normalized = TagNormalizer.normalize(fullTag: raw)
            if !tags.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                tags.append(normalized)
            }
        }

        if accepting.contains(Field.studio), let studio = proposal.studio.value, !studio.isEmpty {
            addTag("studio:\(studio)")
        }
        if accepting.contains(Field.performers), let performers = proposal.actors.value {
            for name in performers where !name.isEmpty { addTag("actor:\(name)") }
        }
        // Exactly what was ticked, nothing inferred. Proposals carry bare
        // names, matching what `Asset.actions` shows; the stored form is
        // prefixed, and adding the unprefixed string would create a tag the
        // filters and the tag list cannot see.
        for tag in acceptedTags.sorted() where !tag.isEmpty {
            addTag(tag.hasPrefix("tag:") ? tag : "tag:\(tag)")
        }
        merged.tags = tags
        return merged
    }
}
