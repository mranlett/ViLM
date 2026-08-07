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
    /// 🚨 The vocabulary says this tag describes a PERFORMER, not a video.
    ///
    /// A source tags its scenes with performer attributes — hair colour,
    /// ethnicity, body type — and those arrived here indistinguishable from a
    /// tag about the video. Worse, they were classified, so `isKnown` was true
    /// and they were **pre-ticked**: matching a video silently proposed filing
    /// the video itself as a tall, and accepting the defaults applied it.
    ///
    /// Still offered, never pre-selected. The graph's standing rule is to show
    /// the operator and refuse to guess, and a person may genuinely want one.
    public let describesPerformer: Bool

    public init(name: String, isKnown: Bool, isExisting: Bool = false,
                describesPerformer: Bool = false) {
        self.name = name
        self.isKnown = isKnown
        self.isExisting = isExisting
        self.describesPerformer = describesPerformer
    }
}

public enum VideoEnrichmentReview {

    /// A credit as the review row shows it: `Alice Smith (as Alicia)`.
    ///
    /// ⭐ Shown because it is the operator's only chance to catch a bad match.
    /// A credited name that looks nothing like the performer is exactly the
    /// signal that the source matched the wrong person, and hiding it would
    /// throw away the evidence at the one moment someone is looking.
    static func described(_ credit: ProposedCredit) -> String {
        guard let creditedAs = credit.creditedAs,
              !creditedAs.isEmpty,
              creditedAs.caseInsensitiveCompare(credit.name) != .orderedSame
        else { return credit.name }
        return "\(credit.name) (as \(creditedAs))"
    }

    /// The credits worth STORING from an accepted proposal.
    ///
    /// ⚠️ Only those that actually say something. A credit carrying neither a
    /// different name nor a billing position records that a performer was
    /// credited normally, which the edge already implies — writing it would
    /// fill the column with rows that mean nothing and make "this one is
    /// interesting" unfindable.
    public static func credits(from proposal: VideoMetadataProposal,
                               accepting: Set<String>) -> [ProposedCredit] {
        guard accepting.contains(Field.performers),
              let performers = proposal.actors.value else { return [] }
        return performers.filter { credit in
            credit.billing != nil
                || (credit.creditedAs.map {
                        !$0.isEmpty && $0.caseInsensitiveCompare(credit.name) != .orderedSame
                    } ?? false)
        }
    }

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
            let additions = performers.filter { !held.contains($0.name.lowercased()) }
            if !additions.isEmpty {
                rows.append(.init(field: Field.performers, label: "Performers", kind: .fill,
                                  current: asset.actors.joined(separator: ", "),
                                  proposed: additions.map(Self.described).joined(separator: ", "),
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
    /// - Parameter performerTraits: folded identities the vocabulary classifies
    ///   as describing a performer. Pass empty to keep the old behaviour.
    public static func tagOptions(for asset: Asset,
                                  proposal: VideoMetadataProposal,
                                  knownTags: Set<String>,
                                  performerTraits: Set<String> = []) -> [VideoTagOption] {
        let held = Set(asset.actions.map { $0.lowercased() })
        let vocabulary = Set(knownTags.map { $0.lowercased() })
        func isTrait(_ name: String) -> Bool {
            performerTraits.contains(TagNormalizer.identityKey(name))
        }

        // The video's OWN tags first, ticked — so the list is the whole picture
        // rather than only what the source wants to add.
        var options = asset.actions.map {
            VideoTagOption(name: $0, isKnown: true, isExisting: true,
                           describesPerformer: isTrait($0))
        }
        for tag in proposal.tags.value ?? [] where !held.contains(tag.lowercased()) {
            options.append(VideoTagOption(name: tag,
                                          isKnown: vocabulary.contains(tag.lowercased()),
                                          isExisting: false,
                                          describesPerformer: isTrait(tag)))
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
        // opening this screen must not propose removing everything. That
        // includes ones describing a performer: unticking is how they come off,
        // and silently proposing removal of tags already applied would be a
        // different kind of surprise.
        //
        // 🚨 A NEW tag describing a performer is never pre-ticked, however
        // familiar it looks. Being in the vocabulary is exactly why these were
        // ticked before — they are classified, so `isKnown` was true — and that
        // is how a video came to be filed as a tall.
        Set(options.filter {
            $0.isExisting || ($0.isKnown && !$0.describesPerformer)
        }.map(\.name))
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

    // MARK: - Which studio the source meant

    /// Applies the studio-level policy to what a source offered.
    ///
    /// A scene names both the imprint that released it and the network that
    /// owns the imprint. `StudioResolution` decides between them; this only
    /// turns a proposal into the two candidates it needs.
    ///
    /// `isVerified` answers whether a studio NAME has already been confirmed —
    /// in practice `enrichmentState == .matched` on its profile.
    public static func studioResolution(proposal: VideoMetadataProposal,
                                        isVerified: (String) -> Bool)
    -> StudioResolution.Outcome {
        func candidate(_ name: String?, _ sourceId: String?,
                       _ level: StudioResolution.Level) -> StudioResolution.Candidate? {
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return StudioResolution.Candidate(name: name, sourceId: sourceId,
                                              level: level, isVerified: isVerified(name))
        }
        return StudioResolution.resolve(
            imprint: candidate(proposal.studio.value, proposal.studioSourceId.value, .imprint),
            parent: candidate(proposal.studioParent.value,
                              proposal.studioParentSourceId.value, .parent))
    }

    /// A copy of the proposal whose studio field carries the decided studio.
    ///
    /// ⚠️ Rewriting the proposal rather than threading the choice through
    /// review, merge and confirm separately: those three have to agree about
    /// which studio this video is getting, and three parameters that could
    /// disagree is exactly how they would drift apart.
    public static func resolvingStudio(_ proposal: VideoMetadataProposal,
                                       to choice: StudioResolution.Candidate)
    -> VideoMetadataProposal {
        var resolved = proposal
        // The source note is kept: where the name came from is still true, and
        // it is what the review row shows to justify the change.
        resolved.studio = ProposedField(choice.name,
                                        sourceNote: choice.level == .parent
                                            ? note(proposal.studioParent.sourceNote, "network")
                                            : proposal.studio.sourceNote)
        resolved.studioSourceId = ProposedField(choice.sourceId)
        return resolved
    }

    private static func note(_ existing: String?, _ suffix: String) -> String? {
        guard let existing, !existing.isEmpty else { return suffix }
        return "\(existing) · \(suffix)"
    }

    /// The studio a source supplied, when the operator accepted it.
    ///
    /// ⭐ A studio that arrived FROM the source is confirmed by definition: the
    /// source knows it exists and knows how it is spelled. That is exactly what
    /// "a lexicon of downloaded and verified studio names" means, and it is the
    /// only route by which a studio becomes verified — nothing looks studios up
    /// directly, so without this a studio could never stop being unconfirmed.
    ///
    /// Returns nil when the source offered a studio the video does not carry
    /// and the operator did not accept it — an unticked conflict confirms
    /// nothing.
    ///
    /// 🚨 **Agreement confirms.** This used to require `accepting` to contain
    /// the studio field, i.e. the studio was verified only when it was WRITTEN.
    /// But `changes(for:)` emits no studio row at all when the video already
    /// carries that studio — so the source agreeing with the library produced
    /// nothing to accept, and the studio was never confirmed. The better the
    /// data already was, the less likely it ever verified. Reported by the
    /// operator as *"the studio name appears on the UI but it isn't recognised
    /// as a studio"* — right and wrong at the same time.
    ///
    /// ⚠️ Returns the name the ASSET carries, not the source's spelling, when
    /// the two differ only by spacing or case. `confirmStudio` keys the profile
    /// by name, and confirming "Coast Line" while every video says "CoastLine"
    /// creates a confirmed profile nothing points at — the gallery looks up
    /// `studio:<tag>` exactly and would still show it unconfirmed.
    public static func confirmedStudio(proposal: VideoMetadataProposal,
                                       accepting: Set<String>,
                                       asset: Asset) -> String? {
        guard let studio = proposal.studio.value, !studio.isEmpty else { return nil }

        // Written just now, at the source's spelling.
        if accepting.contains(Field.studio) { return studio }

        // Already held. The source naming a studio the library already files
        // under is the strongest confirmation available — two independent
        // records agreeing — and it is the case that was silently dropped.
        if let held = asset.studios.first(where: {
            StudioResolution.isSameStudio($0, studio)
        }) {
            return held
        }

        return nil
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
            // ⚠️ The CANONICAL name becomes the tag, never the credited one.
            // Filing a performer under a name they used once would split them
            // into two people — which is the reason the credited name is edge
            // data rather than another string on the video.
            for credit in performers where !credit.name.isEmpty {
                addTag("actor:\(credit.name)")
            }
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
