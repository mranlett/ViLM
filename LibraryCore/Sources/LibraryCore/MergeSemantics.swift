// MergeSemantics.swift
// The shared, non-destructive merge primitives used by both the Actor Library
// Merge and the full-library restore-over-existing. One paradigm: a real
// (non-empty) source value wins a genuine conflict, an empty/nil source never
// wipes an existing destination value, and multi-value fields are unioned so
// neither side loses data.

import Foundation

enum MergeSemantics {
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
