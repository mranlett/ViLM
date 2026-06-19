import Foundation

public struct TagNormalizer {
    /// Normalizes just the value of a tag (e.g. "running fast" -> "Running Fast")
    public static func normalize(tagValue: String) -> String {
        return tagValue.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
    }
    
    /// Normalizes a full tag string preserving its category prefix if present (e.g. "actor:luna" -> "actor:Luna")
    public static func normalize(fullTag: String) -> String {
        let parts = fullTag.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            let category = String(parts[0])
            let value = String(parts[1])
            return "\(category):\(normalize(tagValue: value))"
        } else {
            return normalize(tagValue: fullTag)
        }
    }
}
