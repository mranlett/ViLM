// HeadToHeadModel.swift
// Head to Head — one session of the comparison game (#34).
//
// ⭐ The scoring, the pairing and the persistence are all in LibraryCore and
// already tested there. This holds the part that is genuinely about a SESSION:
// which pair is up, which one is next, what the last comparison was so it can
// be taken back, and how many have been done.
//
// 🚨 Federation. Several libraries can be open at once, and the merged view
// folds one performer across them by identity. Writes therefore go to the
// OWNING library via `LibrarySession.store(forProfile:)` — the same routing
// every other profile edit uses. Writing to the primary instead would put an
// attachment's standing in the wrong catalogue with nothing reporting it,
// which is precisely what the identity-keyed presence map exists to prevent.

import Foundation
import Combine
import SwiftUI
import LibraryCore

@MainActor
final class HeadToHeadModel: ObservableObject {

    struct Side: Identifiable, Equatable {
        let id: String
        let name: String
        let profile: EntityProfile
        /// The library that owns writes for this contender.
        let libraryURL: URL?
        /// Which gallery image is showing. D1: tapping browses.
        var galleryIndex: Int = 0

        /// Primary first, then the gallery — so the first thing shown is the
        /// picture the operator already associates with this performer.
        var images: [String?] {
            var out: [String?] = [profile.photoUrl]
            for url in profile.galleryUrls where url != profile.photoUrl { out.append(url) }
            return out
        }

        var currentImage: String? {
            images.isEmpty ? nil : images[galleryIndex % images.count]
        }

        var hasMoreThanOneImage: Bool { images.count > 1 }
    }

    enum State: Equatable {
        case loading
        case playing(left: Side, right: Side)
        /// T12 — refused with a reason rather than entered and then stuck.
        case unplayable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// D5 — a tally, never a required length.
    @Published private(set) var comparedThisSession = 0
    /// D7 — one step back is enough.
    @Published private(set) var canUndo = false

    private var contenders: [String: PreferenceContender] = [:]
    private var sidesById: [String: Side] = [:]
    /// ⭐ Prefetched. A wait between taps ends a session faster than anything
    /// else, so the next pair is chosen before it is needed and the images
    /// begin loading behind the current one.
    private var upcoming: (left: String, right: String)?
    private var lastComparison: RecordedComparison?

    private let subject: PreferenceSubject = .actor

    // MARK: - Loading

    /// How many contenders the current pool admits — shown so the operator
    /// always knows who is in the game.
    @Published private(set) var poolCount = 0

    func load(profiles: EntityProfileIndex, assets: [Asset],
              photoFileNames: Set<String>, pool: ActorFilterCriteria,
              fallbackLibrary: URL?) async {
        state = .loading
        do {
            let withImages = profiles.actors.filter { Self.hasAnImage($0) }

            // D1b — the pool decides who is IN the game. Reuses the same
            // criteria and the same matcher the actor grid uses, so a filter
            // means the same thing in both places.
            let eligible = Self.pooled(withImages, pool: pool, profiles: profiles,
                                       assets: assets, photoFileNames: photoFileNames)
            poolCount = eligible.count

            guard eligible.count >= 2 else {
                // ⚠️ T12 — names the shortfall in the operator's terms, and
                // says whether the POOL caused it. "Cannot play" alone reads as
                // a bug; "your filter leaves one" says what to change.
                let filtered = !pool.isEmpty
                state = .unplayable(
                    filtered
                    ? "This pool has \(eligible.count == 1 ? "only one performer" : "no performers") with a photo. Widen it to play."
                    : (withImages.isEmpty
                       ? "No performer in this library has a photo yet, so there is nothing to compare."
                       : "Only one performer has a photo, and a comparison needs two."))
                return
            }

            let standings = PreferenceStandings.load(for: eligible, subject: subject,
                                                     fallback: fallbackLibrary)
            var built: [String: PreferenceContender] = [:]
            var sides: [String: Side] = [:]
            for profile in eligible {
                let record = standings[profile.id]
                built[profile.id] = PreferenceContender(
                    id: profile.id,
                    score: record?.preferenceScore
                        ?? PreferenceScore.seeded(byRating: profile.rating),
                    hasImage: true,
                    isRetired: record?.retired ?? false)
                sides[profile.id] = Side(
                    id: profile.id, name: profile.name, profile: profile,
                    libraryURL: LibrarySession.shared.url(forProfile: profile.id)
                        ?? fallbackLibrary)
            }
            contenders = built
            sidesById = sides
            try advance()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Applies the pool criteria, using the SAME matcher the actor grid uses.
    ///
    /// ⚠️ A real `ActorContext` — video counts and photo presence included —
    /// rather than a stubbed one. A pool filtering on video count against
    /// zeroed counts would silently admit nobody, and the operator would see
    /// "no performers" with no idea why.
    private static func pooled(_ candidates: [EntityProfile],
                               pool: ActorFilterCriteria,
                               profiles: EntityProfileIndex,
                               assets: [Asset],
                               photoFileNames: Set<String>) -> [EntityProfile] {
        guard !pool.isEmpty else { return candidates }
        let counts = ActorVideoCounts.build(assets: assets, profiles: profiles)
        return candidates.filter { profile in
            let safeId = ProfileImageNaming.safeId(for: profile.id)
            let hasLocalPhoto = photoFileNames.contains("\(safeId).jpg")
                || photoFileNames.contains { $0.hasPrefix("\(safeId)_") }
            return pool.matches(actor: profile.name,
                                context: .init(profile: profile,
                                               videoCount: counts[profile.name] ?? 0,
                                               hasLocalPhoto: hasLocalPhoto))
        }
    }

    /// ⚠️ D9/T8 — a contender with no image cannot play and is excluded rather
    /// than shown blank. Checks the gallery too: a performer with no primary
    /// but a gallery still has something to show.
    private static func hasAnImage(_ profile: EntityProfile) -> Bool {
        if let url = profile.photoUrl, !url.isEmpty { return true }
        return profile.galleryUrls.contains { !$0.isEmpty }
    }

    // MARK: - Playing

    /// Moves to the prefetched pair, choosing a new one to follow it.
    private func advance() throws {
        let pool = Array(contenders.values)
        let pair: (left: PreferenceContender, right: PreferenceContender)

        if let upcoming,
           let left = contenders[upcoming.left], let right = contenders[upcoming.right],
           left.isEligible, right.isEligible {
            pair = (left, right)
        } else {
            pair = try PreferencePairing.nextPair(from: pool)
        }

        guard var left = sidesById[pair.left.id], var right = sidesById[pair.right.id] else {
            throw PreferencePairingError.notEnoughContenders(eligible: pool.filter(\.isEligible).count)
        }
        left.galleryIndex = 0
        right.galleryIndex = 0
        state = .playing(left: left, right: right)

        // Prefetch, tolerating a pool that has just become unplayable — the
        // pair on screen is still valid and answering it is still useful.
        upcoming = (try? PreferencePairing.nextPair(from: pool)).map { ($0.left.id, $0.right.id) }
    }

    /// D1 — tapping a photo browses that contender's gallery.
    func browse(_ side: Side) {
        guard case .playing(let left, let right) = state else { return }
        var (l, r) = (left, right)
        if side.id == left.id { l.galleryIndex += 1 } else if side.id == right.id { r.galleryIndex += 1 }
        state = .playing(left: l, right: r)
    }

    func choose(_ outcome: PreferenceOutcome) {
        guard case .playing(let left, let right) = state else { return }
        record(outcome, leftId: left.id, rightId: right.id, owner: left.libraryURL)
    }

    /// D6's "neither" — both leave the ranking, no score changes hands.
    ///
    /// ⚠️ No confirmation, deliberately. A dialog on a rapid tapping game is
    /// the friction D5 exists to avoid; undo is the safety net instead.
    func retireBoth() {
        guard case .playing(let left, let right) = state else { return }
        do {
            for side in [left, right] {
                let store = try LibrarySession.shared.store(forProfile: side.id)
                try store.retirePreferenceContender(subject: subject, contenderId: side.id)
                contenders[side.id]?.isRetired = true
            }
            lastComparison = nil
            canUndo = false          // ⚠️ Undo reverses a COMPARISON; see below.
            retiredPair = (left.id, right.id)
            canUndoRetirement = true
            try advance()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Retirement is undone separately from a comparison — they are different
    /// statements, and one step back should return whichever the operator just
    /// did rather than silently the other.
    private var retiredPair: (String, String)?
    @Published private(set) var canUndoRetirement = false

    private func record(_ outcome: PreferenceOutcome,
                        leftId: String, rightId: String, owner: URL?) {
        do {
            // 🚨 The OWNING library. Both contenders may be owned by different
            // ones when several are open, so each side resolves its own.
            let leftStore = try LibrarySession.shared.store(forProfile: leftId)
            let recorded = try leftStore.recordComparison(subject: subject,
                                                          leftId: leftId, rightId: rightId,
                                                          outcome: outcome)
            apply(recorded)
            lastComparison = recorded
            canUndo = true
            canUndoRetirement = false
            comparedThisSession += 1
            try advance()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func apply(_ recorded: RecordedComparison) {
        let updated = PreferenceScoring.apply(recorded.comparison.outcome,
                                              left: recorded.comparison.leftBefore,
                                              right: recorded.comparison.rightBefore)
        contenders[recorded.comparison.leftId]?.score = updated.left
        contenders[recorded.comparison.rightId]?.score = updated.right
    }

    /// D7 — one step back, reversing the score change rather than merely
    /// re-showing the pair.
    func undo() {
        do {
            if let recorded = lastComparison {
                let store = try LibrarySession.shared.store(forProfile: recorded.comparison.leftId)
                try store.undoComparison(recorded)
                contenders[recorded.comparison.leftId]?.score = recorded.comparison.leftBefore
                contenders[recorded.comparison.rightId]?.score = recorded.comparison.rightBefore
                comparedThisSession = max(0, comparedThisSession - 1)
                lastComparison = nil
                canUndo = false
                // Put the pair back up, so the correction is visible.
                upcoming = (recorded.comparison.leftId, recorded.comparison.rightId)
            } else if let retired = retiredPair {
                for id in [retired.0, retired.1] {
                    let store = try LibrarySession.shared.store(forProfile: id)
                    try store.retirePreferenceContender(subject: subject, contenderId: id,
                                                        retired: false)
                    contenders[id]?.isRetired = false
                }
                retiredPair = nil
                canUndoRetirement = false
                upcoming = (retired.0, retired.1)
            } else { return }
            try advance()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
