// EnrichmentReview.swift
// The merge policy and the review model. Core owns both (D5).
//
// Every plugin routes through this. Writing it once means it is tested once and
// cannot be circumvented by a badly behaved plugin — plugins have no write path
// at all, they only return proposals (T6).
//
// The three-way rule:
//   Fills      target blank, source has a value        -> safe, accepted by default
//   Conflicts  target and source disagree              -> NEVER auto-applied
//   Unchanged  agreement, or the source said nothing   -> nothing to do
//
// A blank source value never clears a populated target. Collections union rather
// than replace, so enrichment can never lose a curated entry.

import Foundation

/// One reviewable field.
public struct ProposedChange: Identifiable, Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable {
        case fill
        case conflict
        case unchanged
    }

    /// Stable field key. Used as the selection identity, so it must not change
    /// between building the review and applying it.
    public let id: String
    /// User-facing field name for the review sheet.
    public let label: String
    /// Current value, rendered for display. `nil` means the field is empty.
    public let current: String?
    /// What the plugin proposes, rendered for display.
    public let proposed: String?
    public let kind: Kind
    /// Where the value came from, shown so the user can weigh it.
    public let sourceNote: String?

    public init(id: String, label: String, current: String?, proposed: String?,
                kind: Kind, sourceNote: String? = nil) {
        self.id = id
        self.label = label
        self.current = current
        self.proposed = proposed
        self.kind = kind
        self.sourceNote = sourceNote
    }
}

/// The full field-by-field diff presented to the user before anything is written.
public struct EnrichmentReview: Equatable, Sendable {

    public let sourceName: String
    public let changes: [ProposedChange]

    public init(sourceName: String, changes: [ProposedChange]) {
        self.sourceName = sourceName
        self.changes = changes
    }

    public var fills: [ProposedChange] { changes.filter { $0.kind == .fill } }
    public var conflicts: [ProposedChange] { changes.filter { $0.kind == .conflict } }
    public var unchanged: [ProposedChange] { changes.filter { $0.kind == .unchanged } }

    /// Anything the user could act on. An empty result means the proposal adds
    /// nothing and the sheet can say so instead of showing a blank list.
    public var actionable: [ProposedChange] { fills + conflicts }
    public var hasAnythingToApply: Bool { !actionable.isEmpty }

    /// Pre-ticked selection: **fills only**. Conflicts start unticked because
    /// D5 forbids applying a disagreement without an explicit decision.
    public var defaultAccepted: Set<String> { Set(fills.map(\.id)) }
}

// MARK: - Actor merging

public enum ActorEnrichment {

    /// Field keys. Public so the review sheet and the apply step agree, and so a
    /// test can assert the set rather than guessing at strings.
    public enum Field {
        public static let bio = "bio"
        public static let gender = "gender"
        public static let hairColor = "hairColor"
        public static let countryOfOrigin = "countryOfOrigin"
        public static let birthYear = "birthYear"
        public static let photoUrl = "photoUrl"
        public static let akas = "akas"
        public static let tags = "tags"

        public static let all = [bio, gender, hairColor, countryOfOrigin,
                                 birthYear, photoUrl, akas, tags]
    }

    /// Builds the diff. Pure: no store, no network, no view.
    ///
    /// Only fields `EntityProfile` can currently hold are reviewed. A proposal
    /// may carry career span, birth date or external links — those are accepted
    /// by the protocol but have nowhere to land until the schema work adds them,
    /// and silently discarding them here is preferable to inventing storage.
    public static func review(
        profile: EntityProfile?,
        proposal: ActorMetadataProposal,
        sourceName: String
    ) -> EnrichmentReview {
        var changes: [ProposedChange] = []

        func scalar(_ id: String, _ label: String,
                    current: String?, proposed: ProposedField<some Equatable & Sendable>) {
            let proposedText = proposed.value.map { "\($0)" }
            changes.append(makeChange(id: id, label: label,
                                      current: normalised(current),
                                      proposed: normalised(proposedText),
                                      sourceNote: proposed.sourceNote))
        }

        scalar(Field.bio, "Bio", current: profile?.bio, proposed: proposal.bio)
        scalar(Field.gender, "Gender", current: profile?.gender, proposed: proposal.gender)
        scalar(Field.hairColor, "Hair Colour", current: profile?.hairColor, proposed: proposal.hairColor)
        scalar(Field.countryOfOrigin, "Country", current: profile?.countryOfOrigin, proposed: proposal.countryOfOrigin)
        scalar(Field.birthYear, "Birth Year",
               current: profile?.birthYear.map(String.init), proposed: proposal.birthYear)
        scalar(Field.photoUrl, "Photo", current: profile?.photoUrl, proposed: proposal.photoURL)

        changes.append(collection(id: Field.akas, label: "AKAs",
                                  current: profile?.akas ?? [], proposed: proposal.akas))
        changes.append(collection(id: Field.tags, label: "Tags",
                                  current: profile?.tags ?? [], proposed: proposal.tags))

        return EnrichmentReview(sourceName: sourceName, changes: changes)
    }

    /// Applies only the accepted fields. Anything not in `accepting` is left
    /// exactly as it was — including every conflict the user did not tick.
    public static func apply(
        _ proposal: ActorMetadataProposal,
        to profile: EntityProfile?,
        entityId: String,
        accepting: Set<String>,
        now: Date = Date()
    ) -> EntityProfile {

        func take<T>(_ id: String, _ proposed: ProposedField<T>, _ existing: T?) -> T? {
            guard accepting.contains(id), let value = proposed.value else { return existing }
            return value
        }

        // Collections union rather than replace, so accepting a proposal can add
        // entries but never remove a curated one.
        func merged(_ id: String, _ proposed: ProposedField<[String]>, _ existing: [String]) -> [String] {
            guard accepting.contains(id), let incoming = proposed.value else { return existing }
            var seen = Set(existing.map { $0.lowercased() })
            var out = existing
            for value in incoming {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
                out.append(trimmed)
            }
            return out
        }

        return EntityProfile(
            id: entityId,
            bio: take(Field.bio, proposal.bio, profile?.bio),
            photoUrl: take(Field.photoUrl, proposal.photoURL.mapString(), profile?.photoUrl),
            homePage: profile?.homePage,          // not proposable today
            gender: take(Field.gender, proposal.gender, profile?.gender),
            hairColor: take(Field.hairColor, proposal.hairColor, profile?.hairColor),
            birthYear: take(Field.birthYear, proposal.birthYear, profile?.birthYear),
            countryOfOrigin: take(Field.countryOfOrigin, proposal.countryOfOrigin, profile?.countryOfOrigin),
            rating: profile?.rating,              // user-authored, never proposable
            tags: merged(Field.tags, proposal.tags, profile?.tags ?? []),
            galleryUrls: profile?.galleryUrls ?? [],   // preserved, never proposable
            akas: merged(Field.akas, proposal.akas, profile?.akas ?? []),
            createdAt: profile?.createdAt ?? now
        )
    }

    // MARK: - Classification

    private static func makeChange(id: String, label: String,
                                   current: String?, proposed: String?,
                                   sourceNote: String?) -> ProposedChange {
        let kind: ProposedChange.Kind
        switch (current, proposed) {
        case (_, nil):
            // The source said nothing. Never a change, and never a clear.
            kind = .unchanged
        case (nil, _):
            kind = .fill
        case let (c?, p?):
            kind = (c == p) ? .unchanged : .conflict
        }
        return ProposedChange(id: id, label: label, current: current,
                              proposed: proposed, kind: kind, sourceNote: sourceNote)
    }

    /// Collections can only gain entries, so a proposal is a FILL when it adds
    /// something and UNCHANGED when it does not. It is never a conflict: union
    /// semantics mean nothing curated is at risk.
    private static func collection(id: String, label: String,
                                   current: [String],
                                   proposed: ProposedField<[String]>) -> ProposedChange {
        guard let incoming = proposed.value else {
            return ProposedChange(id: id, label: label,
                                  current: render(current), proposed: nil,
                                  kind: .unchanged, sourceNote: proposed.sourceNote)
        }
        let existing = Set(current.map { $0.lowercased() })
        let additions = incoming
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !existing.contains($0.lowercased()) }

        return ProposedChange(
            id: id, label: label,
            current: render(current),
            proposed: additions.isEmpty ? render(current) : render(current + additions),
            kind: additions.isEmpty ? .unchanged : .fill,
            sourceNote: proposed.sourceNote
        )
    }

    private static func normalised(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    private static func render(_ values: [String]) -> String? {
        values.isEmpty ? nil : values.joined(separator: " | ")
    }
}

private extension ProposedField where Value == URL {
    /// `EntityProfile.photoUrl` is a String; proposals carry a URL.
    func mapString() -> ProposedField<String> {
        ProposedField<String>(value?.absoluteString, sourceNote: sourceNote)
    }
}
