// MergeSemantics.swift
// The shared, non-destructive merge primitives used by both the Actor Library
// Merge and the full-library restore-over-existing. One paradigm: a real
// (non-empty) source value wins a genuine conflict, an empty/nil source never
// wipes an existing destination value, and multi-value fields are unioned so
// neither side loses data.

import Foundation

public enum MergeSemantics {
    /// Source wins when it has a real (non-whitespace) value; otherwise the
    /// destination's value is kept.
    static func coalesce(_ source: String?, _ destination: String?) -> String? {
        if let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return source
        }
        return destination
    }

    /// Order-preserving union: everything in `primary`, then any of `secondary`
    /// not already present.
    static func union(_ primary: [String], _ secondary: [String]) -> [String] {
        var result = primary
        for item in secondary where !result.contains(item) { result.append(item) }
        return result
    }

    /// The multi-library session's read-only actor VIEW: an ordered fold over
    /// each open library's profiles, primary first, then attachments in
    /// precedence (attach) order. Field semantics match the real merge tools —
    /// a higher-precedence real value wins a conflict, nil/empty never wipes,
    /// tags/AKAs/galleries are unioned — but the result is DISPLAY ONLY and
    /// must never be written back to any store: persisting the merged form
    /// would copy one library's data into another, which is exactly what the
    /// session promises not to do.
    public static func mergedProfileView(ordered layers: [[String: EntityProfile]]) -> [String: EntityProfile] {
        var merged: [String: EntityProfile] = [:]
        for layer in layers {
            for (id, profile) in layer {
                if let higher = merged[id] {
                    merged[id] = mergedProfileView(higher: higher, lower: profile)
                } else {
                    merged[id] = profile
                }
            }
        }
        return merged
    }

    /// One fold step: `higher` (higher precedence) wins real conflicts,
    /// `lower` fills gaps, list fields union. `createdAt` takes the earliest
    /// so "recently added actors" reflects first appearance anywhere.
    static func mergedProfileView(higher: EntityProfile, lower: EntityProfile) -> EntityProfile {
        var merged = EntityProfile(
            id: higher.id,
            bio: coalesce(higher.bio, lower.bio),
            photoUrl: higher.photoUrl ?? lower.photoUrl,
            homePage: coalesce(higher.homePage, lower.homePage),
            gender: coalesce(higher.gender, lower.gender),
            hairColor: coalesce(higher.hairColor, lower.hairColor),
            tattoos: coalesce(higher.tattoos, lower.tattoos),
            piercings: coalesce(higher.piercings, lower.piercings),
            birthYear: higher.birthYear ?? lower.birthYear,
            countryOfOrigin: coalesce(higher.countryOfOrigin, lower.countryOfOrigin),
            rating: higher.rating ?? lower.rating,
            tags: union(higher.tags, lower.tags),
            galleryUrls: union(higher.galleryUrls, lower.galleryUrls),
            akas: union(higher.akas, lower.akas),
            createdAt: [higher.createdAt, lower.createdAt].compactMap { $0 }.min(),
            // Career span (v17). Same precedence rule — omitting these would
            // make career data disappear from the merged view whenever a second
            // library is attached.
            birthDate: coalesce(higher.birthDate, lower.birthDate),
            careerSpanRaw: coalesce(higher.careerSpanRaw, lower.careerSpanRaw),
            careerStartYear: higher.careerStartYear ?? lower.careerStartYear,
            careerEndYear: higher.careerEndYear ?? lower.careerEndYear,
            ageAtCareerStart: higher.ageAtCareerStart ?? lower.ageAtCareerStart,
            // Enrichment state (v18): the more recent check wins, so the merged
            // view reflects the latest lookup rather than library precedence.
            enrichmentState: newerChecked(higher, lower).enrichmentState,
            enrichmentSource: newerChecked(higher, lower).enrichmentSource,
            enrichmentCheckedAt: newerChecked(higher, lower).enrichmentCheckedAt,
            links: EntityLink.merged(higher.links, adding: lower.links)
        )
        merged.enrichmentSourceId = higher.enrichmentSourceId ?? lower.enrichmentSourceId
        return merged
    }

    /// Whichever profile was enrichment-checked most recently. Falls back to
    /// `higher` so precedence still decides when neither has been checked.
    static func newerChecked(_ higher: EntityProfile, _ lower: EntityProfile) -> EntityProfile {
        switch (higher.enrichmentCheckedAt, lower.enrichmentCheckedAt) {
        case (nil, nil): return higher
        case (nil, _): return lower
        case (_, nil): return higher
        case let (h?, l?): return h >= l ? higher : lower
        }
    }

    /// Merges a video record from a backup archive (`source`) into the current
    /// library's record (`destination`) for the *same* asset id. Descriptive
    /// fields follow the coalesce rule; "progress" fields never regress
    /// (review status can only move toward reviewed, play count/last-played take
    /// the higher/later value); identity + on-disk fields stay as the
    /// destination has them (the file may have been renamed since the backup).
    static func mergeAsset(source: Asset, into destination: Asset) -> Asset {
        var merged = destination

        // Descriptive fields: a real archive value wins.
        merged.notes = coalesce(source.notes, destination.notes)
        merged.externalLink = coalesce(source.externalLink, destination.externalLink)
        merged.videoName = coalesce(source.videoName, destination.videoName)
        merged.episode = coalesce(source.episode, destination.episode)
        merged.rating = source.rating ?? destination.rating
        merged.seasonNumber = source.seasonNumber ?? destination.seasonNumber
        merged.episodeNumber = source.episodeNumber ?? destination.episodeNumber

        // Tags: unioned so neither side loses any.
        merged.tags = union(source.tags, destination.tags)

        // Progress fields: never regress.
        merged.status = (source.status == .reviewed || destination.status == .reviewed) ? .reviewed : .unreviewed
        merged.playCount = max(source.playCount, destination.playCount)
        merged.lastPlayedAt = [source.lastPlayedAt, destination.lastPlayedAt].compactMap { $0 }.max()

        // Identity / on-disk fields stay as the destination has them.
        return merged
    }
}
