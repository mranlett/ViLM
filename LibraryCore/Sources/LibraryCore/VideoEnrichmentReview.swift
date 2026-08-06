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
    /// This video already carries this tag.
    ///
    /// Shown ticked, and unticking REMOVES it. Without these the list is a
    /// one-way door: a tag applied by mistake is invisible here and can only be
    /// undone somewhere else, which is where a wrong tag quietly survives.
    public let isExisting: Bool

    public init(name: String, isKnown: Bool, isExisting: Bool = false) {
        self.name = name
        self.isKnown = isKnown
        self.isExisting = isExisting
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
        public static let externalLink = "externalLink"
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
        // The release's own page. Only one is storable, and the provider puts
        // the studio's own site first — the durable one, and the one someone
        // following the link actually wants.
        scalar(Field.externalLink, "Link", current: asset.externalLink,
               proposed: proposal.externalLinks.value?.first?.absoluteString,
               note: linkNote(proposal))

        // Studio REPLACES rather than adds. A scene has one releasing studio,
        // so treating it like the performer list — union, never remove — left a
        // wrong studio sitting alongside the right one, and the video then
        // carried two. Accepting a correction has to be able to correct.
        if let studio = proposal.studio.value, !studio.isEmpty {
            let held = asset.studios
            if !held.contains(where: { $0.caseInsensitiveCompare(studio) == .orderedSame }) {
                rows.append(.init(
                    field: Field.studio, label: "Studio",
                    // A studio already recorded and disagreeing is a CONFLICT,
                    // not a fill: accepting it discards what is there, and that
                    // must never happen without being ticked.
                    kind: held.isEmpty ? .fill : .conflict,
                    current: held.joined(separator: ", "),
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
    /// Says how many other addresses were on offer, since only one is storable.
    /// Without it the row looks like the source knew of exactly one page.
    private static func linkNote(_ proposal: VideoMetadataProposal) -> String? {
        let count = proposal.externalLinks.value?.count ?? 0
        guard count > 1 else { return proposal.externalLinks.sourceNote }
        return "\(count - 1) other link\(count == 2 ? "" : "s") not stored"
    }

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
        let held = Set(asset.actions.map { $0.lowercased() })
        let vocabulary = Set(knownTags.map { $0.lowercased() })

        // The video's OWN tags first, ticked — so the list is the whole picture
        // rather than only what the source wants to add.
        var options = asset.actions.map {
            VideoTagOption(name: $0, isKnown: true, isExisting: true)
        }
        for tag in proposal.tags.value ?? [] where !held.contains(tag.lowercased()) {
            options.append(VideoTagOption(name: tag,
                                          isKnown: vocabulary.contains(tag.lowercased()),
                                          isExisting: false))
        }
        // Existing first, then ones already in the vocabulary, then the rest —
        // which is also the order they are ticked in.
        return options.sorted { a, b in
            if a.isExisting != b.isExisting { return a.isExisting }
            if a.isKnown != b.isKnown { return a.isKnown }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
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
        // Existing tags start ticked because they ARE the current state —
        // opening this screen must not propose removing everything.
        Set(options.filter { $0.isExisting || $0.isKnown }.map(\.name))
    }

    /// - Parameter acceptedTags: the exact tag names to add, chosen
    ///   individually. Nothing outside this set is applied, so a tag the
    ///   operator did not tick can never arrive by another route.
    /// The asset with a lookup outcome recorded on it.
    ///
    /// Separate from `merged` because the two happen at different moments: an
    /// outcome is known as soon as the source answers, whereas the merge waits
    /// for the operator to choose what to accept. A video that matched but
    /// whose proposals were all declined has still been looked up, and must not
    /// be offered again as unchecked.
    /// - Parameters:
    ///   - sourceId: the source's own id for the matched record, from
    ///     `PluginCandidate.id`. **This is the match**, and keeping it is what
    ///     turns a later lookup from a re-search into a fetch. Without it every
    ///     run re-guesses which of several same-named records was meant — the
    ///     defect v23 fixed for people and this fixes for videos.
    ///   - sourceUrl: a human-openable link to that record, supplied by the
    ///     provider. Core cannot build one from the id: that would require
    ///     knowing the source's address, and core never names a source.
    ///
    ///   Both are cleared when the state is not a match, so an id can never
    ///   outlive the match it belongs to and be read as evidence of one.
    public static func recordingOutcome(_ asset: Asset,
                                        state: EnrichmentState,
                                        source: String?,
                                        sourceId: String? = nil,
                                        sourceUrl: String? = nil,
                                        checkedAt: Date = Date()) -> Asset {
        var updated = asset
        updated.enrichmentState = state
        updated.enrichmentSource = source
        updated.enrichmentCheckedAt = checkedAt

        if state == .matched {
            if let sourceId {
                // A CHANGED id invalidates the stored link, which described the
                // record we are no longer matched to. Carrying it over would
                // leave the provenance label pointing somewhere plausible and
                // wrong — worse than showing no link at all.
                if sourceId != updated.enrichmentSourceId {
                    updated.enrichmentUrl = sourceUrl
                } else if let sourceUrl {
                    updated.enrichmentUrl = sourceUrl
                }
                updated.enrichmentSourceId = sourceId
            }
            // With no id supplied, BOTH are left as they were. A URL without an
            // id is deliberately ignored rather than stored: a link is not an
            // identity, and recording one would leave a match that can never be
            // fetched by id — the defect this whole change exists to close.
            // A re-confirmation from a provider that returns no id must also
            // not erase an identity already established.
        } else {
            updated.enrichmentSourceId = nil
            updated.enrichmentUrl = nil
        }
        return updated
    }

    /// The studio a source supplied, when the operator accepted it.
    ///
    /// ⭐ A studio that arrived FROM the source is confirmed by definition: the
    /// source knows it exists and knows how it is spelled. That is exactly what
    /// "a lexicon of downloaded and verified studio names" means, and it is the
    /// only route by which a studio becomes verified — nothing looks studios up
    /// directly, so without this a studio could never stop being unconfirmed.
    ///
    /// Returns nil when the studio was not accepted, so an unticked conflict
    /// confirms nothing.
    public static func confirmedStudio(proposal: VideoMetadataProposal,
                                       accepting: Set<String>) -> String? {
        guard accepting.contains(Field.studio),
              let studio = proposal.studio.value,
              !studio.isEmpty else { return nil }
        return studio
    }

    public static func merged(asset: Asset,
                              proposal: VideoMetadataProposal,
                              accepting: Set<String>,
                              acceptedTags: Set<String> = [],
                              offeredTags: [String] = []) -> Asset {
        var merged = asset

        if accepting.contains(Field.seriesTitle), let v = proposal.seriesTitle.value { merged.videoName = v }
        if accepting.contains(Field.seasonNumber), let v = proposal.seasonNumber.value { merged.seasonNumber = v }
        if accepting.contains(Field.episodeNumber), let v = proposal.episodeNumber.value { merged.episodeNumber = v }
        if accepting.contains(Field.episodeTitle) {
            if let v = proposal.episodeTitle.value ?? proposal.title.value { merged.episode = v }
        }
        if accepting.contains(Field.releaseDate), let v = proposal.releaseDate.value { merged.releaseDate = v }
        if accepting.contains(Field.externalLink),
           let v = proposal.externalLinks.value?.first { merged.externalLink = v.absoluteString }

        var tags = merged.tags
        func addTag(_ raw: String) {
            let normalized = TagNormalizer.normalize(fullTag: raw)
            if !tags.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                tags.append(normalized)
            }
        }

        if accepting.contains(Field.studio), let studio = proposal.studio.value, !studio.isEmpty {
            // Replace, not append. The old studio goes only because this field
            // was explicitly accepted — an unticked conflict changes nothing.
            tags.removeAll { $0.hasPrefix("studio:") }
            addTag("studio:\(studio)")
        }
        if accepting.contains(Field.performers), let performers = proposal.actors.value {
            for name in performers where !name.isEmpty { addTag("actor:\(name)") }
        }
        // Unticking an existing tag REMOVES it. Scoped to `offeredTags` so
        // this can only ever affect tags the operator was actually shown — a
        // tag absent from the list is untouched, never silently dropped.
        if !offeredTags.isEmpty {
            let offered = Set(offeredTags.map { $0.lowercased() })
            let keep = Set(acceptedTags.map { $0.lowercased() })
            tags.removeAll { stored in
                guard stored.hasPrefix("tag:") else { return false }
                let bare = String(stored.dropFirst(4)).lowercased()
                return offered.contains(bare) && !keep.contains(bare)
            }
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
