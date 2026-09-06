// ProfileThumbnailNaming.swift
// Where a profile photo's grid-sized derivative lives, and when it is stale.
//
// 🚨 WHY THIS EXISTS — the measurement, not a hunch (#84, spec P1)
//
// A two-pass actor gallery scroll on an iPhone 16 Pro Max cost 30.7 %/hr and
// ~19.9 GiB of allocations, with ~31,000 allocations happening INSIDE a single
// cell materialisation. Two hypotheses were refuted on device before this one:
//
//   • #7  — bitmap cache limits. "Premise disproven twice by measurement, and
//           the attempted fix was reverted."
//   • #14 — SwiftUI view-graph churn. `_printChanges()` showed ~4 parent
//           evaluations across an entire scroll. Normal LazyVGrid behaviour.
//
// What #14's probe DID name: one cell materialisation reads and fully decodes
// the profile JPEG. On the drive library those average 4.2 GB / 9,499 files,
// with the largest at 4–5 MB — decoded to draw a grid cell.
//
// ⚠️ The trap this type exists to avoid. `CGImageSourceCreateThumbnailAtIndex`
// downsamples the OUTPUT but still reads and parses the WHOLE JPEG, so the
// #7 attempt left churn flat (19.47 → 20.68 GiB) while retained memory rose 9×
// — smaller results, identical work to produce them. Decoding cheaply requires
// a physically smaller FILE, which is what a derivative is. Downsampling at
// read time is not a substitute and has already been measured failing.
//
// This type is deliberately pure: paths and a freshness rule, no CoreGraphics
// and no filesystem. Generation lives in the app layer; the decision about
// WHICH file and WHETHER it is still valid is testable and lives here.

import Foundation

/// Naming and freshness for the grid-sized derivatives of profile photos.
///
/// Convention, mirroring `ProfileImageNaming`:
/// - Sources live in `.catalog/profiles/` as `<safeId>.jpg` (primary) or
///   `<safeId>_<sha256(token)>.jpg` (gallery).
/// - Derivatives live in `.catalog/profileThumbs/` as `<sourceBase>@<max>.jpg`.
///
/// The size is in the filename on purpose: a library that later renders a
/// larger cell gets a second derivative rather than silently reusing one too
/// small to look right, and the two can coexist.
public enum ProfileThumbnailNaming {

    /// Directory name under the catalog, beside `profiles/` and `thumbnails/`.
    public static let directoryName = "profileThumbs"

    /// Catalog-relative path, for callers that build from a library root.
    public static let relativePath = ".catalog/profileThumbs"

    /// The default grid cell size in pixels.
    ///
    /// Actor grid cells render around 160pt; at 2–3× that is 320–480px. 384
    /// covers the common case without a second derivative, and a 384px JPEG is
    /// roughly two orders of magnitude smaller than a 4–5 MB source.
    public static let defaultMaxPixelSize = 384

    /// The derivative filename for a source profile filename.
    ///
    /// - Parameters:
    ///   - sourceFileName: e.g. `A1B2.jpg` or `A1B2_9f86d0….jpg`
    ///   - maxPixelSize: longest edge in pixels
    /// - Returns: `nil` when the name is empty — callers should fall back to
    ///   the source rather than invent a path.
    ///
    /// ⚠️ Returns nil rather than defaulting, because a derivative path that
    /// silently means something else is how a cache serves the wrong face.
    public static func fileName(forSourceFileName sourceFileName: String,
                                maxPixelSize: Int = defaultMaxPixelSize) -> String? {
        let trimmed = sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxPixelSize > 0 else { return nil }
        let base = (trimmed as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        return "\(base)@\(maxPixelSize).jpg"
    }

    /// Whether a derivative may be used, given both modification dates.
    ///
    /// 🚨 This rule is the whole correctness story, and it is the r4 shape
    /// (#21) waiting to happen if it is got wrong. The PRIMARY photo's filename
    /// is FIXED per entity — starring a different gallery photo overwrites
    /// `<safeId>.jpg` in place. A derivative keyed on the path alone would
    /// therefore keep serving the OLD face forever, which is exactly the bug
    /// where "starring a photo does not change the profile photo after the
    /// first save": there, `fileExists` meant "this actor has a primary" rather
    /// than "this image is cached".
    ///
    /// So freshness is a comparison, never a presence check. A derivative is
    /// usable only when it is at least as new as its source. Equal counts as
    /// fresh: a derivative written in the same second as its source is a
    /// derivative OF that source.
    public static func isFresh(derivativeModified: Date, sourceModified: Date) -> Bool {
        derivativeModified >= sourceModified
    }
}
