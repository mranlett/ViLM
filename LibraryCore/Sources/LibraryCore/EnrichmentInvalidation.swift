// EnrichmentInvalidation.swift
// When a recorded lookup result stops being trustworthy.
//
// Operator's rule: "No match can be solved by manual data entry then
// rechecking. Once the record is changed manually, the no-match status should
// be removed and the record can be rechecked."
//
// This is a better rule than time-based expiry: the verdict clears when the
// data it was based on changes, rather than on a schedule nobody chose. An
// actor that could not be found because they had no aliases becomes findable
// the moment an alias is added, and should return to the queue at that instant.

import Foundation

public enum EnrichmentInvalidation {

    /// Fields an external lookup actually uses to find and disambiguate a
    /// record. Editing any of these can change the outcome; editing a rating or
    /// a note cannot.
    ///
    /// Name is absent deliberately: it is the identity key and the editor
    /// cannot change it. Renaming goes through the global rename path, which
    /// rewrites the entity id entirely.
    public static func matchInputsChanged(from previous: EntityProfile,
                                          to edited: EntityProfile) -> Bool {
        // AKAs are the strongest disambiguator a lookup has — adding one is the
        // single most likely way to turn a no-match into a match.
        if Set(previous.akas.map { $0.lowercased() }) != Set(edited.akas.map { $0.lowercased() }) {
            return true
        }
        if previous.birthDate != edited.birthDate { return true }
        if previous.birthYear != edited.birthYear { return true }
        return false
    }

    /// The enrichment fields to persist after a manual edit.
    ///
    /// Returns cleared values when an unresolved verdict has been invalidated,
    /// and the existing ones otherwise.
    ///
    /// A `.matched` result is NEVER cleared. Editing a matched actor's birth
    /// year should not push them back into the backlog — the match already
    /// happened and the operator can re-run a lookup deliberately.
    public static func afterManualEdit(
        previous: EntityProfile,
        edited: EntityProfile
    ) -> (state: EnrichmentState?, source: String?, checkedAt: Date?) {

        guard let state = edited.enrichmentState, state.needsAttention else {
            return (edited.enrichmentState, edited.enrichmentSource, edited.enrichmentCheckedAt)
        }
        guard matchInputsChanged(from: previous, to: edited) else {
            return (edited.enrichmentState, edited.enrichmentSource, edited.enrichmentCheckedAt)
        }
        // Back to "not yet checked" — NOT to a different verdict. The previous
        // answer is stale, and inventing a new one without running a lookup
        // would be a guess.
        return (nil, nil, nil)
    }
}
