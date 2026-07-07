import Foundation
import CryptoKit

/// Single source of truth for how actor/studio/tag profile photos are named
/// on disk under `.catalog/profiles`. Previously this hashing scheme was
/// duplicated across several app-layer views; consolidating it here means
/// export/import (and any future consumer) can never drift from what the
/// viewers actually read.
///
/// Convention:
/// - The "primary" photo lives at `<safeId>.jpg`.
/// - Every other gallery photo lives at `<safeId>_<sha256(token)>.jpg`, where
///   `token` is the entry's value in `EntityProfile.galleryUrls` (typically
///   the source URL string, or the literal sentinel `"local://primary"` for a
///   locally-added photo with no remote source).
public enum ProfileImageNaming {

    /// `local://primary` is a placeholder gallery-array entry meaning "the
    /// primary photo, which has no remote URL." It always resolves to the
    /// primary filename, never a hashed gallery filename.
    public static let localPrimaryToken = "local://primary"

    public static func safeId(for entityId: String) -> String {
        entityId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    public static func primaryFileName(for entityId: String) -> String {
        "\(safeId(for: entityId)).jpg"
    }

    public static func galleryFileName(for entityId: String, token: String) -> String {
        "\(safeId(for: entityId))_\(sha256Hex(token)).jpg"
    }

    /// Prefix shared by every gallery file for this entity — useful for
    /// "does any cached photo exist" lookups that don't have a specific token.
    public static func galleryFilePrefix(for entityId: String) -> String {
        "\(safeId(for: entityId))_"
    }

    /// The file name a token resolves to. `isGallery` mirrors the flag callers
    /// already compute (typically `token != profile.photoUrl`); the local-only
    /// sentinel always forces primary treatment even if `isGallery` is true.
    public static func fileName(for entityId: String, token: String?, isGallery: Bool) -> String {
        if isGallery, let token, token != localPrimaryToken {
            return galleryFileName(for: entityId, token: token)
        }
        return primaryFileName(for: entityId)
    }

    public static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
