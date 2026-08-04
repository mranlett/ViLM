// ActorEnrichmentModel.swift
// Drives one actor's enrichment: search -> choose -> review -> apply.
//
// TRACKED and PUBLIC, and it names no source (D7/D9). Everything it knows comes
// from the registry and the provider protocol, so this file reads identically
// whether the installed plugin is a film database or anything else.
//
// The model never writes to the library. It produces an EntityProfile and hands
// it back; the editor puts the values in its fields and the user still has to
// press Save. Human review is enforced by construction, not by a warning.

import Foundation
// ObservableObject and @Published are Combine types, and this file has no
// SwiftUI import to pull them in — the model is deliberately view-free.
// LibrarySession, PlaybackCoordinator and QuickActionRouter all do the same.
import Combine
import LibraryCore

@MainActor
final class ActorEnrichmentModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case searching
        /// More than one match. The user picks; we never guess an identity.
        case choosing([PluginCandidate])
        case fetching
        case reviewing(EnrichmentReview)
        /// The source has no record under this name. Not an error.
        case noMatches
        /// A match was found and it proposes nothing we do not already have.
        case nothingToApply
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Field ids the user has ticked. Seeded from the review's own default,
    /// which pre-ticks fills and leaves conflicts off (core's policy, not ours).
    @Published var accepted: Set<String> = []

    /// Adopt the source's spelling of the name.
    ///
    /// ON by default (operator's decision, after testing): when a lookup only
    /// matched because the local name was a misspelling or an alias, adopting
    /// the source's spelling is almost always the point of the exercise.
    ///
    /// Still kept OUT of `accepted`: every other proposal writes a column on
    /// this row, but a name IS the row's identity. Accepting it rewrites the
    /// `actor:` tag on every video and moves every profile photo file — and if
    /// the new name already exists locally, merges two actors into one. That
    /// last case is why the toggle stays visible and separate rather than being
    /// folded in with the field fills.
    @Published var acceptsCanonicalName = true

    /// Gallery photos the user has ticked, as absolute strings.
    ///
    /// Starts EMPTY on purpose. Scalar fills are pre-ticked because they cost
    /// nothing, but photos are downloaded and stored per actor — importing
    /// eleven images nobody asked for is a cost the user did not choose. Zero to
    /// all, with zero as the default.
    @Published var acceptedPhotos: Set<String> = []

    /// Gallery images on offer, largest first. Empty when the source has none.
    private(set) var galleryCandidates: [URL] = []

    let provider: any ActorMetadataProvider

    /// Held between review and apply. The review is a rendering of this; the
    /// apply step needs the typed values.
    private var proposal: ActorMetadataProposal?
    /// Shown in the review header so the user can always see *who* was matched,
    /// including in the single-match case that skips the picker.
    private(set) var chosen: PluginCandidate?

    /// The candidates the search returned, RETAINED after one is chosen.
    ///
    /// Picking wrongly used to mean cancelling the whole sheet and starting
    /// again, which re-ran the search — repeated identical queries against the
    /// source purely because the UI had thrown the list away.
    private(set) var candidates: [PluginCandidate] = []

    /// True when there is a list worth going back to.
    var canReturnToPicker: Bool { candidates.count > 1 }

    private let entityId: String
    private let currentProfile: EntityProfile?

    /// The name as the library currently stores it, from the `actor:Name` id.
    var localName: String {
        guard let colon = entityId.firstIndex(of: ":") else { return entityId }
        return String(entityId[entityId.index(after: colon)...])
    }

    /// The source's spelling, when it differs from ours.
    ///
    /// `nil` when they agree, or when no candidate has been chosen. A pure
    /// case difference still counts — the operator may well want the source's
    /// capitalisation — but see `renameWouldBeNoOp`.
    var proposedName: String? {
        guard let title = chosen?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              title != localName
        else { return nil }
        return title
    }

    /// True when the rename would normalise to the same tag, so the store would
    /// early-return and nothing would change. Worth saying rather than offering
    /// an action that silently does nothing.
    var renameWouldBeNoOp: Bool {
        guard let proposedName else { return true }
        return TagNormalizer.normalize(fullTag: "actor:\(proposedName)")
            == TagNormalizer.normalize(fullTag: entityId)
    }

    /// The name to rename to, or nil when the user declined or there is nothing
    /// to do. This is what the editor acts on.
    var acceptedCanonicalName: String? {
        guard acceptsCanonicalName, !renameWouldBeNoOp else { return nil }
        return proposedName
    }

    init(provider: any ActorMetadataProvider,
         entityId: String,
         currentProfile: EntityProfile?) {
        self.provider = provider
        self.entityId = entityId
        self.currentProfile = currentProfile
    }

    // MARK: - Flow

    func search(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed("This actor has no name to search for.")
            return
        }
        phase = .searching
        do {
            let candidates = try await provider.search(name: trimmed)
            switch candidates.count {
            case 0:
                phase = .noMatches
            case 1:
                // One match still goes through the review sheet, and the sheet
                // shows who was matched — so skipping the picker saves a tap
                // without ever hiding the identity decision.
                await choose(candidates[0])
            default:
                self.candidates = candidates
                phase = .choosing(candidates)
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Return to the picker without touching the network.
    ///
    /// Resets the review state so a second choice starts clean rather than
    /// inheriting the first candidate's ticked fields.
    func returnToPicker() {
        guard canReturnToPicker else { return }
        chosen = nil
        proposal = nil
        accepted = []
        acceptedPhotos = []
        galleryCandidates = []
        // Back to the default, not to off — picking a different candidate
        // proposes a different name, and it should arrive in the same state a
        // first choice would.
        acceptsCanonicalName = true
        phase = .choosing(candidates)
    }

    func choose(_ candidate: PluginCandidate) async {
        chosen = candidate
        phase = .fetching
        do {
            let proposal = try await provider.fetch(actorId: candidate.id)
            self.proposal = proposal
            let review = ActorEnrichment.review(profile: currentProfile,
                                                proposal: proposal,
                                                sourceName: provider.displayName)
            let newPhotos = (proposal.galleryURLs.value ?? [])
                .filter { !Set(currentProfile?.galleryUrls ?? []).contains($0.absoluteString) }
            guard review.hasAnythingToApply || !newPhotos.isEmpty else {
                phase = .nothingToApply
                return
            }
            accepted = review.defaultAccepted
            // Photos the profile already has are not offered again.
            let existing = Set(currentProfile?.galleryUrls ?? [])
            galleryCandidates = (proposal.galleryURLs.value ?? [])
                .filter { !existing.contains($0.absoluteString) }
            phase = .reviewing(review)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// True when anything at all is ticked — a field or a photo.
    var canApply: Bool {
        !accepted.isEmpty || !acceptedPhotos.isEmpty || acceptedCanonicalName != nil
    }

    /// The accepted fields and photos, merged onto the current profile.
    ///
    /// Returns rather than saves: the caller drops these into the editor's
    /// fields, and the user presses Save. Nothing reaches disk from here.
    func apply() -> EntityProfile? {
        guard let proposal else { return nil }
        var merged = ActorEnrichment.apply(proposal,
                                     to: currentProfile,
                                     entityId: entityId,
                                     accepting: accepted,
                                     acceptingGalleryURLs: galleryCandidates
                                        .map(\.absoluteString)
                                        .filter { acceptedPhotos.contains($0) })

        // Record that a lookup ran and what it concluded (schema v18).
        // Reaching apply() means the user chose a candidate and accepted at
        // least one value, so this actor is matched and off the backlog.
        //
        // The SOURCE is the provider's own display name, supplied at runtime —
        // core stores what a plugin handed it and names nothing itself.
        merged.enrichmentState = .matched
        merged.enrichmentSource = provider.displayName
        merged.enrichmentCheckedAt = Date()
        return merged
    }

    func togglePhoto(_ url: URL) {
        let key = url.absoluteString
        if acceptedPhotos.contains(key) { acceptedPhotos.remove(key) } else { acceptedPhotos.insert(key) }
    }

    var allPhotosSelected: Bool {
        !galleryCandidates.isEmpty
            && acceptedPhotos.count == galleryCandidates.count
    }

    func toggleAllPhotos() {
        acceptedPhotos = allPhotosSelected ? [] : Set(galleryCandidates.map(\.absoluteString))
    }

    /// The profile to save when the operator decides this person is not in the
    /// source at all.
    ///
    /// A HUMAN decision, never inferred. An automated search returning nothing
    /// means only that — the name may be misspelled or the search term wrong —
    /// so the machine records `noMatch` and leaves the entity in the queue. This
    /// is the operator saying "I looked; stop asking."
    func markUnmatchable() -> EntityProfile {
        var profile = currentProfile ?? EntityProfile(id: entityId)
        profile.enrichmentState = .unmatchable
        profile.enrichmentSource = provider.displayName
        profile.enrichmentCheckedAt = Date()
        return profile
    }

    /// The outcome to record when the user closes the sheet WITHOUT applying.
    ///
    /// A lookup that found nothing is a result worth keeping — otherwise the
    /// same actor is re-checked on every run and never leaves the backlog. Nil
    /// while the flow is still in progress, or when the user simply cancelled.
    var unappliedOutcome: EnrichmentState? {
        switch phase {
        case .noMatches: return .noMatch
        case .choosing: return .ambiguous   // dismissed at the picker
        case .nothingToApply: return .matched
        default: return nil
        }
    }

    func toggle(_ id: String) {
        if accepted.contains(id) { accepted.remove(id) } else { accepted.insert(id) }
    }

    // MARK: - Errors

    /// Plugin errors carry no user-facing wording of their own, and a raw
    /// `Error` description is not something to put in front of someone. Each
    /// case gets a sentence that says what happened and what to do about it.
    static func message(for error: Error) -> String {
        guard let error = error as? PluginError else {
            return "Something went wrong looking this actor up. Please try again."
        }
        switch error {
        case .missingCredential:
            return "This plugin needs its key before it can look anything up. Add it in Settings › Plugins."
        case .unauthorized:
            return "The source rejected the saved key. Check it in Settings › Plugins."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter, seconds > 0 {
                return "The source asked us to slow down. Try again in about \(Int(seconds.rounded())) seconds."
            }
            return "The source asked us to slow down. Try again shortly."
        case .notFound:
            return "The source no longer has a record for this match."
        case .failed(let detail):
            return detail
        }
    }
}
