// CountryFlagHelper.swift
// Maps a country name (or ISO-style prefix) to its flag emoji; used when
// saving an actor's country of origin so the flag renders alongside it.

import Foundation

struct CountryFlagHelper {
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
