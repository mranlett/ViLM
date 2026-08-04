// ActorPhotoDeduplicator.swift
// Finds redundant actor profile photos and plans their removal.
//
// Two kinds of redundancy, and they need different treatment:
//
//   Identical bytes — the same file arriving twice, typically because one
//   library merged from another under a different token. Safe to collapse
//   without judgement: the survivor is bit-for-bit what was removed.
//
//   The same picture at different sizes — a thumbnail imported early and the
//   full portrait imported later. These have different hashes and cannot be
//   found by content. The larger one is worth keeping and the smaller one is
//   pure loss, which is why the plan chooses by pixel count.
//
// Planning is pure and takes measurements as input, so it is testable without
// decoding a single image. `PhotoMeasurement` is produced by the caller — see
// `ActorPhotoScanner` for the ImageIO implementation.

import Foundation

/// What the planner needs to know about one photo file on disk.
public struct PhotoMeasurement: Equatable, Sendable {
    /// The gallery token (or the primary's token) this file is referenced by.
    public let token: String
    public let fileName: String
    /// SHA-256 of the file's bytes — identity for exact duplicates.
    public let contentHash: String
    /// A perceptual hash: equal (or near-equal) for the same picture at
    /// different sizes or encodings. Nil when the image could not be decoded,
    /// which excludes it from near-duplicate grouping but not from exact.
    public let perceptualHash: UInt64?
    public let pixelCount: Int
    public let byteCount: Int
    /// Whether the profile currently points at this file as its primary photo.
    public let isPrimary: Bool

    public init(token: String, fileName: String, contentHash: String,
                perceptualHash: UInt64?, pixelCount: Int, byteCount: Int,
                isPrimary: Bool) {
        self.token = token
        self.fileName = fileName
        self.contentHash = contentHash
        self.perceptualHash = perceptualHash
        self.pixelCount = pixelCount
        self.byteCount = byteCount
        self.isPrimary = isPrimary
    }
}

/// One set of photos judged to be the same picture.
public struct DuplicatePhotoGroup: Equatable, Sendable, Identifiable {
    /// Scoped by actor: tokens are only unique WITHIN an actor, and
    /// `local://primary` in particular repeats across most of the library. A
    /// list keyed on the token alone would collide for nearly every row.
    public var id: String { "\(actorId)|\(keep.token)" }

    public let actorId: String
    public let keep: PhotoMeasurement
    public let remove: [PhotoMeasurement]
    /// True when the members differ only in size/encoding rather than bytes.
    /// Worth surfacing: an exact match needs no confirmation, a visual one
    /// does.
    public let isVisualMatch: Bool

    public var reclaimedBytes: Int { remove.reduce(0) { $0 + $1.byteCount } }

    /// The removal promotes a different file to primary.
    public var changesPrimary: Bool { remove.contains { $0.isPrimary } }
}

public enum ActorPhotoDeduplicator {

    /// How close two perceptual hashes must be to count as the same picture.
    ///
    /// Zero would miss re-encodes of the same image, which is the main case
    /// here; a large threshold starts merging two different photos from the
    /// same shoot, which is unrecoverable once the file is deleted. Six bits
    /// out of sixty-four is deliberately conservative — this deletes files, so
    /// a missed duplicate is much cheaper than a wrong one.
    public static let defaultHammingThreshold = 6

    /// Groups one actor's photos, choosing a survivor for each set.
    ///
    /// Exact matches are collapsed first so a set of identical files never
    /// splits across visual groups.
    public static func groups(actorId: String,
                              photos: [PhotoMeasurement],
                              hammingThreshold: Int = defaultHammingThreshold) -> [DuplicatePhotoGroup] {
        guard photos.count > 1 else { return [] }

        var result: [DuplicatePhotoGroup] = []
        var consumed = Set<String>()   // tokens already placed in a group

        // Exact duplicates: identical bytes.
        var byContent: [String: [PhotoMeasurement]] = [:]
        for photo in photos { byContent[photo.contentHash, default: []].append(photo) }
        for hash in byContent.keys.sorted() {
            let members = byContent[hash] ?? []
            guard members.count > 1 else { continue }
            let ordered = rank(members)
            result.append(DuplicatePhotoGroup(actorId: actorId,
                                              keep: ordered[0],
                                              remove: Array(ordered.dropFirst()),
                                              isVisualMatch: false))
            ordered.forEach { consumed.insert($0.token) }
        }

        // Visual duplicates among what's left: one representative per distinct
        // content hash, so identical files already handled above don't pair up
        // with each other again.
        var remaining: [PhotoMeasurement] = []
        var seenContent = Set<String>()
        for photo in photos where !consumed.contains(photo.token) {
            guard seenContent.insert(photo.contentHash).inserted else { continue }
            remaining.append(photo)
        }

        var used = Set<String>()
        for (i, photo) in remaining.enumerated() {
            guard let hash = photo.perceptualHash, !used.contains(photo.token) else { continue }
            var cluster = [photo]
            for other in remaining[(i + 1)...] {
                guard let otherHash = other.perceptualHash, !used.contains(other.token) else { continue }
                if hammingDistance(hash, otherHash) <= hammingThreshold {
                    cluster.append(other)
                }
            }
            guard cluster.count > 1 else { continue }
            cluster.forEach { used.insert($0.token) }
            let ordered = rank(cluster)
            result.append(DuplicatePhotoGroup(actorId: actorId,
                                              keep: ordered[0],
                                              remove: Array(ordered.dropFirst()),
                                              isVisualMatch: true))
        }

        return result
    }

    /// Best survivor first.
    ///
    /// Resolution leads because that is the operator's stated preference and
    /// the only property that is genuinely lost by deleting the wrong file.
    /// The current primary breaks ties so an equal-quality swap doesn't move
    /// the profile photo for no reason, and byte count breaks the rest —
    /// between two files of the same dimensions the larger is the less
    /// compressed.
    static func rank(_ photos: [PhotoMeasurement]) -> [PhotoMeasurement] {
        photos.sorted { a, b in
            if a.pixelCount != b.pixelCount { return a.pixelCount > b.pixelCount }
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            if a.byteCount != b.byteCount { return a.byteCount > b.byteCount }
            return a.token < b.token   // total order, so plans are reproducible
        }
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// The profile as it should be once `groups` are applied: removed tokens
    /// dropped from the gallery, and the primary promoted to the survivor when
    /// the old primary is being deleted.
    ///
    /// Never leaves the profile pointing at a file that is about to go — that
    /// would render as a broken portrait with no obvious cause.
    public static func revised(profile: EntityProfile,
                               applying groups: [DuplicatePhotoGroup]) -> EntityProfile {
        let removedTokens = Set(groups.flatMap { $0.remove.map(\.token) })
        guard !removedTokens.isEmpty else { return profile }

        var revised = profile
        revised.galleryUrls = profile.galleryUrls.filter { !removedTokens.contains($0) }

        if let current = profile.photoUrl, removedTokens.contains(current) {
            // Promote the survivor from whichever group held the old primary.
            let promoted = groups.first { $0.remove.contains { $0.token == current } }?.keep.token
            revised.photoUrl = promoted
            if let promoted, !revised.galleryUrls.contains(promoted) {
                revised.galleryUrls.insert(promoted, at: 0)
            }
        }
        return revised
    }
}
