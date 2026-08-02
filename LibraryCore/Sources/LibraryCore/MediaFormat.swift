// MediaFormat.swift
// Display formatting for container metadata: duration, file size, resolution
// and bitrate.
//
// Extracted from DuplicateDetectionView so the DISPLAY CONTRACT can be pinned by
// unit tests. This exists for F6: once duration, width, height and codec are read
// from SQLite instead of being re-parsed from the container on every hover, the
// strings the user sees must be unchanged. What these functions produce is the
// thing that must not move.
//
// Pure and locale-stable: `String(format:)` is used without a locale, so the
// decimal separator and digits are fixed regardless of region. The one exception
// is `byteCount`, which delegates to ByteCountFormatter and IS locale-aware — see
// its note.

import Foundation

public enum MediaFormat {

    /// `M:SS`, or `H:MM:SS` once the clip runs an hour or longer.
    ///
    /// Seconds are rounded, not truncated, so 59.6s reads as `1:00` rather than `0:59`.
    /// Negative inputs are clamped to zero rather than producing a negative clock.
    public static func duration(seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Human-readable file size.
    ///
    /// Delegates to `ByteCountFormatter` with `.file` style, so the exact string is
    /// locale- and OS-dependent ("1.2 MB" vs "1,2 MB"). Tests therefore pin the
    /// delegation and the structure, not a literal.
    public static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `WIDTH×HEIGHT`, or `nil` when either dimension is unknown.
    ///
    /// Dimensions of zero mean "not loaded", not "zero pixels", so they are omitted
    /// from the summary rather than rendered as `0×0`.
    public static func resolution(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// The at-a-glance comparison line: size · resolution · bitrate · duration.
    ///
    /// Only the size is unconditional. Each other component is omitted entirely when
    /// unknown — the separator count shrinks with it, so an unknown value never shows
    /// as an empty gap or a placeholder.
    public static func metaLine(
        sizeBytes: Int64,
        width: Int,
        height: Int,
        bitrateMbps: Double?,
        durationSeconds: Double?
    ) -> String {
        var parts: [String] = [byteCount(sizeBytes)]
        if let res = resolution(width: width, height: height) { parts.append(res) }
        if let mbps = bitrateMbps { parts.append(String(format: "%.1f Mbps", mbps)) }
        if let duration = durationSeconds { parts.append(self.duration(seconds: duration)) }
        return parts.joined(separator: " · ")
    }
}
