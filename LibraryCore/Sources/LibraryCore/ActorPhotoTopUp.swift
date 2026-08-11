// ActorPhotoTopUp.swift
// Filling in galleries for performers the library has barely any pictures of
// (#44).
//
// ⭐ Measured before building: 316 actors on the drive have a primary photo and
// no gallery, and 315 of those already carry a source id — so this is a direct
// fetch by id, never a name search that could attach the wrong person. That is
// what makes the tool safe enough to run over hundreds of rows unattended.
//
// 🚨 THE RULE: only ADD to the gallery, never touch `photoUrl`.
//
// R4 of the Actor & Tag Browsing spec was THREE stacked bugs about a starred
// photo not becoming the profile picture, each invisible until the one before
// it was fixed. A tool that re-fetches images is exactly where a fourth comes
// from: the source's idea of a primary is not the operator's starred choice,
// and reassigning it would silently undo a decision they made by hand.
//
// ⚠️ Pure. Choosing who needs topping up and deciding what a fetch changes are
// both separable from doing it, and only these need testing hard.

import Foundation

public enum ActorPhotoTopUp {

    /// One performer's standing in the worklist.
    public struct Candidate: Equatable, Sendable, Identifiable {
        public let profile: EntityProfile
        /// Distinct images the library holds — the primary plus the gallery.
        public let photoCount: Int
        /// ⚠️ False when the performer has never been matched. Shown as needing
        /// a match rather than silently dropped, or the operator is left
        /// wondering why someone with one photo is absent from a list of
        /// people with one photo.
        public let canFetch: Bool

        public var id: String { profile.id }
    }

    /// How many images before a performer is considered adequately covered.
    public static let defaultThreshold = 2

    /// Who needs more pictures, thinnest first.
    ///
    /// ⚠️ Sorted ascending by photo count and then by NAME. Without the second
    /// key the order among the hundreds of actors with exactly one photo would
    /// depend on how the profiles happened to be loaded, and the list would
    /// reshuffle every time it opened.
    /// - Parameter includingExhausted: show performers the source already had
    ///   nothing more for. Off by default, and offered rather than permanent —
    ///   the source gains pictures over time, so "nothing more" is a fact about
    ///   a moment, not forever.
    public static func worklist(_ profiles: [EntityProfile],
                                threshold: Int = defaultThreshold,
                                includingExhausted: Bool = false) -> [Candidate] {
        profiles.compactMap { profile -> Candidate? in
            let count = imageCount(profile)
            guard count < threshold else { return nil }
            // 🚨 The convergence rule. Without it a performer the source has
            // one picture of can never reach the threshold, so they sat on the
            // list permanently and were re-fetched on every run, always for
            // nothing — the list could not be worked to the end.
            guard includingExhausted || !isExhausted(profile) else { return nil }
            return Candidate(profile: profile, photoCount: count,
                             canFetch: hasSourceIdentity(profile))
        }
        .sorted {
            $0.photoCount == $1.photoCount
                ? $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending
                : $0.photoCount < $1.photoCount
        }
    }

    /// Distinct pictures the library holds for a performer.
    ///
    /// ⚠️ The primary is counted only when the gallery does not already list
    /// it. A profile whose `photoUrl` also appears in `galleryUrls` has one
    /// picture, not two, and counting it twice would hide a thin profile from
    /// the very list built to find it.
    static func imageCount(_ profile: EntityProfile) -> Int {
        var urls = Set(profile.galleryUrls.filter { !$0.isEmpty })
        if let photo = profile.photoUrl, !photo.isEmpty { urls.insert(photo) }
        return urls.count
    }

    /// The source was asked and had nothing we do not already hold.
    ///
    /// ⭐ Compared against what we HELD at the time, so a picture arriving
    /// later by any route makes them eligible again on its own. Nothing has to
    /// remember to clear a flag.
    public static func isExhausted(_ profile: EntityProfile) -> Bool {
        guard profile.photoTopUpAt != nil, let held = profile.photoTopUpHeld else { return false }
        return imageCount(profile) <= held
    }

    /// Records that the source had nothing more, for a profile as it stands.
    ///
    /// ⚠️ Pure — returns the profile to save. Deciding is separable from
    /// writing, which is the rule the rest of this type follows.
    public static func markingExhausted(_ profile: EntityProfile,
                                        at date: Date = Date()) -> EntityProfile {
        var marked = profile
        marked.photoTopUpAt = date
        marked.photoTopUpHeld = imageCount(profile)
        return marked
    }

    static func hasSourceIdentity(_ profile: EntityProfile) -> Bool {
        !(profile.enrichmentSourceId ?? "").isEmpty && !(profile.enrichmentSource ?? "").isEmpty
    }

    /// 🚨 What a fetch changes: the gallery gains what it did not have, and
    /// NOTHING else moves.
    ///
    /// Returns nil when there is nothing new, so a caller can tell "topped up"
    /// from "already had everything the source offers" without comparing
    /// profiles itself.
    public static func applying(_ fetched: [URL], to profile: EntityProfile) -> EntityProfile? {
        let existing = Set(profile.galleryUrls)
        let additions = fetched.map(\.absoluteString).filter { !existing.contains($0) }

        // ⚠️ Deduped against itself too — a source listing one image twice
        // must not add two entries.
        var seen = existing
        let fresh = additions.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return nil }

        var updated = profile
        // 🚨 Appended. Replacing the array would discard photos the operator
        // added by hand, and `photoUrl` is not assigned AT ALL — see the rule
        // at the top of this file.
        updated.galleryUrls = profile.galleryUrls + fresh
        return updated
    }
}
