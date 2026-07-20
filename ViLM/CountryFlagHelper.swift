// CountryFlagHelper.swift
// Maps a country name (or ISO-style prefix) to its flag emoji; used when
// saving an actor's country of origin so the flag renders alongside it.

import Foundation

// Pure, stateless country↔flag lookups — marked `nonisolated` so the CSV
// import (which runs on a background task) can call them without tripping the
// project's default main-actor isolation.
nonisolated struct CountryFlagHelper {
    private static let countryMapping: [String: String] = {
        var map: [String: String] = [
            "united states": "🇺🇸",
            "usa": "🇺🇸",
            "us": "🇺🇸",
            "united kingdom": "🇬🇧",
            "uk": "🇬🇧",
            "england": "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
            "scotland": "🏴󠁧󠁢󠁳󠁣󠁴󠁿",
            "wales": "🏴󠁧󠁢󠁷󠁬󠁳󠁿",
            "south korea": "🇰🇷",
            "north korea": "🇰🇵",
            "russia": "🇷🇺",
            "czech republic": "🇨🇿"
        ]
        
        let locale = Locale(identifier: "en_US")
        for regionCode in Locale.Region.isoRegions {
            if let name = locale.localizedString(forRegionCode: regionCode.identifier)?.lowercased() {
                let flag = emojiFlag(for: regionCode.identifier)
                if !flag.isEmpty {
                    map[name] = flag
                }
            }
        }
        return map
    }()
    
    private static func emojiFlag(for countryCode: String) -> String {
        let base : UInt32 = 127397
        var flag = ""
        for v in countryCode.uppercased().unicodeScalars {
            guard let scalar = UnicodeScalar(base + v.value) else { continue }
            flag.unicodeScalars.append(scalar)
        }
        return String(flag)
    }

    /// Removes flag emoji from a country string, returning just the name
    /// (e.g. "United States 🇺🇸" -> "United States"). Handles both regional-
    /// indicator flags and the tag-sequence subdivision flags (England,
    /// Scotland, Wales). Used to keep flag glyphs out of CSV, which can't
    /// carry them reliably.
    static func strippedOfFlag(_ text: String) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            let v = scalar.value
            let isRegionalIndicator = (0x1F1E6...0x1F1FF).contains(v) // 🇦–🇿
            let isWavingBlackFlag = v == 0x1F3F4                      // 🏴 base of subdivision flags
            let isTagCharacter = (0xE0000...0xE007F).contains(v)      // tag sequence payload
            let isVariationSelector = v == 0xFE0F
            return !(isRegionalIndicator || isWavingBlackFlag || isTagCharacter || isVariationSelector)
        }
        return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
    }

    /// Returns the country name with its flag appended (e.g. "Russia" ->
    /// "Russia 🇷🇺"), matching how the profile editors store it. A no-op if
    /// the name already contains the flag or no flag is known.
    static func withFlag(_ countryName: String) -> String {
        let name = countryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return name }
        let flag = flagEmoji(for: name)
        if !flag.isEmpty && !name.contains(flag) {
            return "\(name) \(flag)"
        }
        return name
    }

    static func flagEmoji(for countryName: String) -> String {
        let name = countryName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // Try exact match first
        if let exact = countryMapping[name] {
            return exact
        }
        
        // Try partial match with word boundaries
        // Sort keys by length descending to match longer multi-word countries first
        let sortedKeys = countryMapping.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))\\b"
            if name.range(of: pattern, options: .regularExpression) != nil {
                return countryMapping[key] ?? ""
            }
        }
        
        return ""
    }
}
