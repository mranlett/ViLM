// StudioBatchPolicy.swift
// What an unattended studio run is allowed to do.
//
// The same shape as `ActorBatchPolicy`, decision for decision, for the reason
// that file already gives: a library where "match everything" means one thing
// for people and another for companies is a library nobody can reason about.
// Three batch screens that behave differently is three things to learn.
//
// The three shared rules:
//
//   1. Exactly one candidate, or nothing is written. Different reason from the
//      actor case, same conclusion — two networks can use the same imprint
//      name, which is why a studio carries a source id at all.
//   2. FILLS only. A conflict means the library already holds a value.
//   3. Ambiguity is recorded and handed back, never resolved.
//
// What is genuinely different is below: a studio match asserts a SECOND node
// and an edge, and that is the whole reason the tool is worth building.

import Foundation

/// A studio's parent, as an unattended run is allowed to treat it.
public enum ParentDisposition: Equatable, Sendable {
    /// The source named a network and the library had none. Recorded.
    case recorded(name: String)
    /// ⚠️ The library already records a DIFFERENT network. Reported, never
    /// overwritten: which company owns an imprint is a fact about the world
    /// that the operator may know better than the source, and the graph's
    /// standing rule is that it refuses to guess. `GraphSync` reports rather
    /// than resolves for the same reason.
    case conflict(existing: String, offered: String)
    /// The library already records this network. Nothing to do.
    case unchanged
    /// The source named no network.
    case none
}

public enum StudioBatchOutcome: Equatable, Sendable {
    /// Applied unattended. Carries what was written and what happened to the
    /// parent, so the run is auditable.
    case applied(fields: [String], parent: ParentDisposition)
    /// Found something, but a person has to choose.
    case queued(candidateCount: Int)
    case noMatch
    case skipped(reason: String)
    case failed(String)

    public var recordedState: EnrichmentState? {
        switch self {
        case .applied: return .matched
        case .queued: return .ambiguous
        case .noMatch: return .noMatch
        // A failure is not a verdict. Leaving the state alone means the next
        // run tries again rather than treating a network blip as an answer.
        case .failed, .skipped: return nil
        }
    }
}

public enum StudioBatchPolicy {

    /// Field ids, matching how the actor side names them so a report reads the
    /// same whichever run produced it.
    public enum Field {
        public static let name = "name"
        public static let bio = "bio"
        public static let akas = "akas"
        public static let logoUrl = "logo_url"
        public static let homePage = "home_page"
        public static let links = "links"
        public static let parent = "parent"
    }

    /// Why this studio is not worth examining.
    ///
    /// ⚠️ Identical to the actor and video rules, `ambiguous` included.
    /// Ambiguity means a PERSON has to choose, and a re-run cannot choose —
    /// examining it again spends a rate-limited request to reach the same dead
    /// end. Left out, a library accumulating ambiguities gets slower every run
    /// while doing no more work.
    public static func skipReason(for profile: EntityProfile) -> String? {
        switch profile.enrichmentState {
        case .matched: return "already matched"
        case .unmatchable: return "you ruled this one out"
        case .ambiguous: return "waiting on your decision"
        default: return nil
        }
    }

    /// ⚠️ The logo, like the actor photo, is never set unattended — excluded
    /// even when the slot is empty. It is the one field where being wrong is
    /// immediately and visibly wrong on every screen the studio appears on,
    /// and an unattended run has nobody to notice.
    public static let neverUnattended: Set<String> = [Field.logoUrl]

    /// Whether a search result may be applied without asking.
    ///
    /// One candidate only. The actor rule exists because two people share a
    /// name; this one exists because two networks can use the same imprint
    /// name — which is precisely why `studioSourceId` was added. Same rule,
    /// arrived at independently.
    public static func isDecisive(candidateCount: Int) -> Bool {
        candidateCount == 1
    }

    /// What may be written into a studio profile without review.
    ///
    /// ⚠️ A studio's NAME is never rewritten unattended, even when the library
    /// has none of its own to lose. The name is the join key that every video's
    /// `studio:` tag is filed under, so changing it is a library-wide rename
    /// wearing the costume of a field update — and `Repair Tag Spelling` is the
    /// screen that does renames, with the operator looking at it.
    public static func autoApplicableFields(current: EntityProfile,
                                            proposal: StudioMetadataProposal) -> Set<String> {
        var fields: Set<String> = []
        // ⚠️ `nil` means the source had nothing to say, which is not the same
        // as an empty value and must never clear a populated field (D5). Each
        // of these therefore requires BOTH an offered value and an empty slot.
        if proposal.bio.value != nil, current.bio == nil { fields.insert(Field.bio) }
        if proposal.homePage.value != nil, current.homePage == nil {
            fields.insert(Field.homePage)
        }
        if let akas = proposal.akas.value, !akas.isEmpty, current.akas.isEmpty {
            fields.insert(Field.akas)
        }
        if let links = proposal.externalLinks.value, !links.isEmpty, current.links.isEmpty {
            fields.insert(Field.links)
        }
        return fields.subtracting(neverUnattended)
    }

    /// What an unattended run may do about the parent.
    ///
    /// - Parameter existing: the network the library already records, if any.
    public static func parentDisposition(existing: String?,
                                         proposal: StudioMetadataProposal) -> ParentDisposition {
        guard let offered = proposal.parentName.value,
              !offered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }
        guard let existing, !existing.isEmpty else { return .recorded(name: offered) }
        // Folded, so a respelling of the same network is not a conflict —
        // "Example Network" and "ExampleNetwork" are one company, and treating
        // them as a disagreement would fill the report with non-events.
        if StudioResolution.isSameStudio(existing, offered) { return .unchanged }
        return .conflict(existing: existing, offered: offered)
    }
}

/// What a whole run did.
public struct StudioBatchReport: Sendable, Equatable {
    public private(set) var applied = 0
    public private(set) var queued = 0
    public private(set) var noMatch = 0
    public private(set) var skipped = 0
    public private(set) var failed = 0
    public private(set) var fieldsWritten = 0
    /// Networks recorded for the first time. Reported separately because it is
    /// the figure that says the hierarchy is being built, which is the reason
    /// this run exists at all.
    public private(set) var parentsRecorded = 0
    /// Networks the source disagreed with the library about. Nothing was
    /// changed for these — they are handed back.
    public private(set) var parentConflicts = 0

    public init() {}

    public mutating func record(_ outcome: StudioBatchOutcome) {
        switch outcome {
        case let .applied(fields, parent):
            applied += 1
            fieldsWritten += fields.count
            switch parent {
            case .recorded: parentsRecorded += 1
            case .conflict: parentConflicts += 1
            case .unchanged, .none: break
            }
        case .queued: queued += 1
        case .noMatch: noMatch += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        }
    }

    public var examined: Int { applied + queued + noMatch + failed }
}
