// HeadToHeadModel.swift
// Head to Head — one session of the comparison game (#34, #38).
//
// ⭐ The scoring, the pairing and the persistence are all in LibraryCore and
// already tested there. This holds the part that is genuinely about a SESSION:
// which pair is up, which one is next, what the last comparison was so it can
// be taken back, and how many have been done.
//
// ⭐ D1 runs ONE mechanic over two subjects, and this file is where that is
// honoured: everything from `advance()` down is written in contender ids and
// knows nothing about whether it is ranking performers or videos. What differs
// per subject is loading (who is in the pool, what makes them eligible) and
// presentation, which is `Side.Kind` and the view's problem.
//
// ⚠️ The alternative — a second model for videos — was rejected. Undo is the
// subtle part (a first-ever comparison must DELETE a row rather than write the
// seed back), and two copies of it would drift.
//
// 🚨 Federation. Several libraries can be open at once, and the merged view
// folds one performer across them by identity. Writes therefore go to the
// OWNING library — the same routing every other profile edit uses. Writing to
// the primary instead would put an attachment's standing in the wrong
// catalogue with nothing reporting it, which is precisely what the
// identity-keyed presence map exists to prevent.

import Foundation
import Combine
import SwiftUI
import LibraryCore

@MainActor
final class HeadToHeadModel: ObservableObject {

    struct Side: Identifiable, Equatable {
        let id: String
        let name: String
        /// The library that owns writes for this contender.
        let libraryURL: URL?
        /// Which image is showing. D1: tapping browses.
        ///
        /// ⚠️ Unbounded on purpose. An actor knows how many pictures it has;
        /// a video does not until its contact sheet has been sliced, which
        /// happens in the view. Both sides wrap with `%` against a count they
        /// actually know.
        var galleryIndex: Int = 0
        let kind: Kind

        /// What this contender IS, and therefore how it is shown (D1).
        enum Kind: Equatable {
            /// Shows a primary photo; tapping advances through the gallery.
            case actor(EntityProfile, knownFor: ActorKnownFor.Summary)
            /// Shows a contact-sheet frame; tapping advances through the other
            /// frames. 🚨 NEVER autoplays — the game is a rapid visual
            /// judgement, and a video that starts talking mid-session ends the
            /// session.
            case video(Asset)
        }

        var profile: EntityProfile? {
            if case .actor(let profile, _) = kind { return profile }
            return nil
        }

        var asset: Asset? {
            if case .video(let asset) = kind { return asset }
            return nil
        }

        /// ⭐ What the library knows them for. The photo is a REMINDER of who
        /// this is; these are what the judgement is actually about.
        var knownFor: ActorKnownFor.Summary {
            if case .actor(_, let knownFor) = kind { return knownFor }
            return .init(titles: [], videoCount: 0)
        }

        /// Primary first, then the gallery — so the first thing shown is the
        /// picture the operator already associates with this performer.
        ///
        /// Empty for a video: its frames are sliced out of a contact sheet on
        /// disk rather than being a list of urls.
        var images: [String?] {
            guard let profile else { return [] }
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

    /// ⚠️ Set by whichever `load` ran, and read by every write below. One
    /// ladder per subject, and a session never mixes them.
    private(set) var subject: PreferenceSubject = .actor

    // MARK: - Loading

    /// How many contenders the current pool admits — shown so the operator
    /// always knows who is in the game.
    @Published private(set) var poolCount = 0

    func load(profiles: EntityProfileIndex, assets: [Asset],
              photoFileNames: Set<String>, pool: ActorFilterCriteria,
              fallbackLibrary: URL?) async {
        state = .loading
        subject = .actor
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
            // One pass over the assets for everyone, rather than a scan per
            // contender as each pair comes up.
            let knownFor = ActorKnownFor.build(assets: assets, profiles: profiles)
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
                    id: profile.id, name: profile.name,
                    libraryURL: LibrarySession.shared.url(forProfile: profile.id)
                        ?? fallbackLibrary,
                    kind: .actor(profile,
                                 knownFor: knownFor[profile.name]
                                    ?? .init(titles: [], videoCount: 0)))
            }
            contenders = built
            sidesById = sides
            try advance()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// #38 / D1 — the same game over videos.
    ///
    /// ⚠️ Eligibility is a picture ON DISK, not a picture in the record. A
    /// video's still is a generated artifact and a library that has not built
    /// contact sheets yet would otherwise fill the game with black rectangles.
    func loadVideos(assets: [Asset], profiles: EntityProfileIndex,
                    akaMap: [String: String], pool: AssetFilterCriteria,
                    fallbackLibrary: URL?) async {
        state = .loading
        subject = .video
        do {
            let owners = Dictionary(
                assets.map { ($0.id, LibrarySession.shared.url(for: $0.id) ?? fallbackLibrary) },
                uniquingKeysWith: { first, _ in first })
            let imaged = await Self.assetsWithAStill(among: assets, owners: owners)
            let withImages = assets.filter { imaged.contains($0.id) }

            // D1b — the same criteria and the same matcher the video grid
            // uses, so a filter means the same thing in both places.
            let eligible = withImages.filter { asset in
                pool.isEmpty || pool.matches(
                    asset,
                    mappedActors: AssetFilterCriteria.mappedActors(for: asset, akaMap: akaMap),
                    entityProfiles: profiles)
            }
            poolCount = eligible.count

            guard eligible.count >= 2 else {
                let filtered = !pool.isEmpty
                state = .unplayable(
                    filtered
                    ? "This pool has \(eligible.count == 1 ? "only one video" : "no videos") with a still. Widen it to play."
                    : (withImages.isEmpty
                       ? "No video in this library has a thumbnail or contact sheet yet, so there is nothing to compare. Generate them and the game fills up."
                       : "Only one video has a still, and a comparison needs two."))
                return
            }

            let standings = PreferenceStandings.load(
                ids: eligible.map { $0.id.uuidString }, subject: subject,
                owner: { id in UUID(uuidString: id).flatMap { owners[$0] ?? nil } },
                fallback: fallbackLibrary)

            var built: [String: PreferenceContender] = [:]
            var sides: [String: Side] = [:]
            for asset in eligible {
                let id = asset.id.uuidString
                let record = standings[id]
                built[id] = PreferenceContender(
                    id: id,
                    score: record?.preferenceScore
                        ?? PreferenceScore.seeded(byRating: asset.rating),
                    hasImage: true,
                    isRetired: record?.retired ?? false)
                sides[id] = Side(id: id,
                                 name: ActorKnownFor.displayTitle(asset),
                                 libraryURL: owners[asset.id] ?? fallbackLibrary,
                                 kind: .video(asset))
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

    /// The videos that have something to show — a poster frame, a contact
    /// sheet, or both.
    ///
    /// ⚠️ ONE directory listing per library rather than a `fileExists` per
    /// video. Two thousand videos is four thousand stat calls on a screen whose
    /// whole point is that it opens instantly, and a listing gives the same
    /// answer. Off the main actor, because it is still disk work.
    private static func assetsWithAStill(among assets: [Asset],
                                         owners: [Asset.ID: URL?]) async -> Set<UUID> {
        let libraries = Set(owners.values.compactMap { $0 })
        let names: Set<String> = await Task.detached(priority: .userInitiated) {
            var out: Set<String> = []
            for library in libraries {
                for folder in ["thumbnails", "contactSheets"] {
                    let dir = library.appendingPathComponent(".catalog/\(folder)")
                    if let found = try? FileManager.default
                        .contentsOfDirectory(atPath: dir.path) {
                        out.formUnion(found)
                    }
                }
            }
            return out
        }.value
        return Set(assets.map(\.id).filter { names.contains("\($0.uuidString).jpg") })
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

    /// D1 — tapping an image browses that contender's other images.
    func browse(_ side: Side) {
        guard case .playing(let left, let right) = state else { return }
        var (l, r) = (left, right)
        if side.id == left.id { l.galleryIndex += 1 } else if side.id == right.id { r.galleryIndex += 1 }
        state = .playing(left: l, right: r)
    }

    func choose(_ outcome: PreferenceOutcome) {
        guard case .playing(let left, let right) = state else { return }
        record(outcome, leftId: left.id, rightId: right.id)
    }

    /// D6's "neither" — both leave the ranking, no score changes hands.
    ///
    /// ⚠️ No confirmation, deliberately. A dialog on a rapid tapping game is
    /// the friction D5 exists to avoid; undo is the safety net instead.
    func retireBoth() {
        guard case .playing(let left, let right) = state else { return }
        do {
            for side in [left, right] {
                let store = try store(forContender: side.id)
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

    private func record(_ outcome: PreferenceOutcome, leftId: String, rightId: String) {
        do {
            // 🚨 The OWNING library. Both contenders may be owned by different
            // ones when several are open, so each side resolves its own.
            let leftStore = try store(forContender: leftId)
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
                let store = try store(forContender: recorded.comparison.leftId)
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
                    let store = try store(forContender: id)
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

    /// The library a standing must be written to.
    ///
    /// 🚨 One routing rule for both subjects. A performer is resolved by
    /// identity because the merged view folds one person across libraries; a
    /// video is resolved by the asset map, which is the same resolver every
    /// other per-asset write already goes through.
    private func store(forContender id: String) throws -> LibraryStore {
        switch subject {
        case .actor:
            return try LibrarySession.shared.store(forProfile: id)
        case .video:
            guard let assetId = UUID(uuidString: id) else {
                throw HeadToHeadError.notAVideoContender(id)
            }
            return try LibrarySession.shared.store(for: assetId)
        }
    }
}

/// ⚠️ Its own error rather than borrowing one from the store. A video
/// contender's id IS its asset uuid, so a non-uuid here means the session was
/// built with the wrong subject — a programming mistake, and it should not be
/// reported as something the operator did.
enum HeadToHeadError: LocalizedError {
    case notAVideoContender(String)

    var errorDescription: String? {
        switch self {
        case .notAVideoContender(let id):
            return "“\(id)” is not a video, so its standing has nowhere to be written."
        }
    }
}
