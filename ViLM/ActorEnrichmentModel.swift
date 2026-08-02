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

    private let entityId: String
    private let currentProfile: EntityProfile?

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
                phase = .choosing(candidates)
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
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
    var canApply: Bool { !accepted.isEmpty || !acceptedPhotos.isEmpty }

    /// The accepted fields and photos, merged onto the current profile.
    ///
    /// Returns rather than saves: the caller drops these into the editor's
    /// fields, and the user presses Save. Nothing reaches disk from here.
    func apply() -> EntityProfile? {
        guard let proposal else { return nil }
        return ActorEnrichment.apply(proposal,
                                     to: currentProfile,
                                     entityId: entityId,
                                     accepting: accepted,
                                     acceptingGalleryURLs: galleryCandidates
                                        .map(\.absoluteString)
                                        .filter { acceptedPhotos.contains($0) })
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
