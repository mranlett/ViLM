// CountryName.swift
// One stored form for a country, so it groups as one value.
//
// 🚨 Presentation was being stored in the data. The editor appended a flag
// emoji on save ("US 🇺🇸"); the plugin wrote the bare name ("US"). Measured on
// the device 2026-08-11: 94 stored values that are really 57 countries, 37 of
// them split, and 1,309 of 1,332 profiles sitting on a split value. Filtering
// by country offered the same country twice, with different people under each.
//
// ⭐ The codebase already knew. `EnrichmentReview.countryKey` folds the flag
// away for comparison — "a raw string comparison reported a conflict on EVERY
// enrichment" — and `ActorCSV` strips it on export and re-attaches on import.
// Three workarounds around a value that should never have carried a flag.
//
// ⚠️ Normalised at the STORE, exactly as tags are, rather than at the five
// call sites that write a country. A rule enforced in one place cannot be
// half-applied by a caller that had not heard of it.

import Foundation

public enum CountryName {

    /// The form to store: the name, without decoration.
    ///
    /// The flag belongs to rendering — see `CountryFlagHelper.withFlag` in the
    /// app, which puts it back for display.
    public static func canonical(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // ⚠️ Scalar-wise rather than by character, so a flag — which is two
        // regional-indicator scalars — is removed whole. Letters, marks and
        // ordinary punctuation in a real name (Côte d'Ivoire, Timor-Leste) are
        // kept; symbols and pictographs are not.
        let kept = raw.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation
              || scalar.properties.generalCategory == .otherSymbol
              || (0x1F1E6...0x1F1FF).contains(scalar.value))
        }
        let cleaned = String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
