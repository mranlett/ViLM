// ActorPhotoScanner.swift
// Reads actor photo files and turns them into measurements the deduplicator
// can plan from, then applies an approved plan.
//
// Kept apart from the planner so the decisions stay testable without images:
// everything here touches disk or CoreGraphics, and nothing here decides what
// to delete.

import Foundation
import ImageIO
import CoreGraphics

public struct ActorPhotoScanReport: Sendable {
    public let groups: [DuplicatePhotoGroup]
    public let filesScanned: Int
    public let actorsScanned: Int

    public var reclaimableBytes: Int { groups.reduce(0) { $0 + $1.reclaimedBytes } }
    public var removableCount: Int { groups.reduce(0) { $0 + $1.remove.count } }
}

public enum ActorPhotoScanner {

    /// Dimensions read from metadata, without decoding pixels.
    private static func pixelSize(of url: URL) -> (w: Int, h: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// A 64-bit difference hash: the image reduced to 9×8 grey, each pixel
    /// compared with its right-hand neighbour.
    ///
    /// Chosen over comparing the pixels themselves because it is invariant to
    /// scale and to re-encoding, which is exactly the duplication that arises
    /// when the same portrait is imported once as a thumbnail and once at full
    /// size. Decoding goes through a thumbnail request so a 5 MB JPEG is never
    /// fully expanded just to produce eight bytes.
    static func differenceHash(of url: URL) -> UInt64? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bits: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                bits <<= 1
                if pixels[row * w + col] > pixels[row * w + col + 1] { bits |= 1 }
            }
        }
        return bits
    }

    /// Measures every photo file an actor's profile references.
    ///
    /// Tokens that have no file on disk are skipped rather than reported: a
    /// gallery URL that was never downloaded is not a duplicate, it is simply
    /// absent, and offering to "remove" it would be misleading.
    public static func measure(profile: EntityProfile, profilesDir: URL) -> [PhotoMeasurement] {
        var out: [PhotoMeasurement] = []
        var seenFiles = Set<String>()

        for token in tokens(of: profile) {
            let isPrimary = (profile.photoUrl == token)
            let fileName = isPrimary
                ? ProfileImageNaming.primaryFileName(for: profile.id)
                : ProfileImageNaming.galleryFileName(for: profile.id, token: token)
            guard seenFiles.insert(fileName).inserted else { continue }

            let url = profilesDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url) else { continue }
            let size = pixelSize(of: url) ?? (0, 0)

            out.append(PhotoMeasurement(
                token: token,
                fileName: fileName,
                contentHash: ProfileImageNaming.sha256Hex(data),
                perceptualHash: differenceHash(of: url),
                pixelCount: size.w * size.h,
                byteCount: data.count,
                isPrimary: isPrimary
            ))
        }
        return out
    }

    /// Primary first, then the gallery — so an equal-quality tie keeps the
    /// photo the profile already shows.
    private static func tokens(of profile: EntityProfile) -> [String] {
        var ordered: [String] = []
        if let primary = profile.photoUrl, !primary.isEmpty { ordered.append(primary) }
        for token in profile.galleryUrls where !ordered.contains(token) { ordered.append(token) }
        return ordered
    }

    /// Scans a whole library and returns what could be removed. Reads only —
    /// nothing is deleted until `apply` is called with a chosen subset.
    public static func scan(store: LibraryStore,
                            libraryURL: URL,
                            hammingThreshold: Int = ActorPhotoDeduplicator.defaultHammingThreshold,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ActorPhotoScanReport {
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        let profiles = try store.fetchAllEntityProfiles().filter { $0.type == "actor" }

        var groups: [DuplicatePhotoGroup] = []
        var filesScanned = 0
        for (i, profile) in profiles.enumerated() {
            let measured = measure(profile: profile, profilesDir: profilesDir)
            filesScanned += measured.count
            groups += ActorPhotoDeduplicator.groups(actorId: profile.id,
                                                    photos: measured,
                                                    hammingThreshold: hammingThreshold)
            progress?(i + 1, profiles.count)
        }
        return ActorPhotoScanReport(groups: groups,
                                    filesScanned: filesScanned,
                                    actorsScanned: profiles.count)
    }

    /// Deletes the redundant files and rewrites the affected profiles.
    ///
    /// The profile is saved BEFORE its files are deleted. If the process dies
    /// between the two, the library holds a profile that no longer references
    /// a file that still exists on disk — a harmless orphan the next scan can
    /// clean up. The other order would leave a profile pointing at a file that
    /// is gone, which renders as a broken portrait.
    @discardableResult
    public static func apply(_ groups: [DuplicatePhotoGroup],
                             store: LibraryStore,
                             libraryURL: URL) throws -> Int {
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        let byActor = Dictionary(grouping: groups, by: \.actorId)
        var removed = 0

        for (actorId, actorGroups) in byActor {
            guard let profile = try store.fetchEntityProfile(for: actorId) else { continue }
            let revised = ActorPhotoDeduplicator.revised(profile: profile, applying: actorGroups)
            try store.saveEntityProfile(revised)

            for group in actorGroups {
                for photo in group.remove {
                    let url = profilesDir.appendingPathComponent(photo.fileName)
                    if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
                }
            }
        }
        return removed
    }
}
