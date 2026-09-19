// ActorProfilePhotoRepair.swift
// Resets a performer's profile photo when it no longer resolves to a locally
// downloaded file, promoting an already-downloaded gallery photo in its place
// (#97).
//
// 🚨 THE RULE: only repairs a BROKEN primary — one whose file is missing from
// disk — never replaces a primary that already resolves locally, however its
// `photoUrl` string compares to anything else. `ActorPhotoTopUp` (the sibling
// "Get More Photos" fetch) exists specifically because touching `photoUrl` is
// dangerous (R4's three stacked bugs); this type is the one deliberate,
// narrow exception to that rule, and it is just as strict about its own
// boundary: it never touches a WORKING primary, only repairs a genuinely
// broken one.
//
// ⚠️ Never goes online. The operator's own words: "We do not go online to
// display the profile images once downloaded from an initial online
// sourcing." A gallery entry whose file was never downloaded is not a
// candidate — only a gallery token that ALREADY has bytes on disk is ever
// promoted.
//
// ⭐ The identity of "the primary photo" is the FILENAME `<safeId>.jpg`
// (`ProfileImageNaming`), not the `photoUrl` string — `ProfileImageView`
// resolves the primary by filename regardless of what token `photoUrl`
// holds. So "photoUrl does not resolve to a local image" reduces to one
// on-disk check, not a string comparison: does `<safeId>.jpg` exist?

import Foundation

public enum ActorProfilePhotoRepair {

    /// One performer whose primary photo is broken, and what to promote.
    public struct Candidate: Equatable, Sendable, Identifiable {
        public let profile: EntityProfile
        /// The gallery token whose file will become the new primary — always
        /// one that already has bytes on disk.
        public let promote: String

        public var id: String { profile.id }
    }

    /// Who needs their primary repaired, and what already-downloaded photo
    /// would fix it.
    ///
    /// ⭐ Built on `ActorPhotoScanner.measure`, the same reconciliation the
    /// duplicate-photo scanner already trusts, rather than a second
    /// expression of "does this token's file exist". That function already
    /// skips a token with no file on disk (a gallery URL never downloaded is
    /// absent, not broken) and already knows which measured token is the
    /// primary (`isPrimary`) by filename, not by comparing strings.
    ///
    /// ⚠️ A profile whose ONLY gallery entry is the `local://primary`
    /// sentinel, with no other photo downloaded, correctly produces no
    /// candidate here even when broken: that sentinel is a placeholder for
    /// the primary file itself, and `measure` can never find real bytes at
    /// the hashed gallery filename its literal string would produce. That is
    /// the honest answer — there is nothing local left to recover — not a
    /// bug in this function.
    public static func worklist(_ profiles: [EntityProfile], profilesDir: URL) -> [Candidate] {
        profiles.compactMap { profile in
            let measured = ActorPhotoScanner.measure(profile: profile, profilesDir: profilesDir)
            // The primary already resolves to a file on disk — nothing broken.
            guard !measured.contains(where: \.isPrimary) else { return nil }
            // `measure` walks primary-then-gallery in `galleryUrls` order, and
            // the primary slot is absent here, so the first surviving entry is
            // the first gallery photo that was actually downloaded.
            guard let promote = measured.first(where: { !$0.isPrimary })?.token else {
                return nil // nothing local to promote — cannot repair without going online
            }
            return Candidate(profile: profile, promote: promote)
        }
    }

    /// Promotes `candidate.promote`'s file to the primary filename and
    /// returns the updated profile. Performs real file I/O — the write side
    /// of `worklist`'s pure decision, the same split `RelocationPlan` /
    /// `RelocationMover` use.
    ///
    /// - Parameter copy: test seam. Defaults to reading the gallery file's
    ///   bytes and writing them atomically to the primary path — the same
    ///   idiom the "star this photo" editor already uses (never `moveItem`,
    ///   which would delete the gallery copy the profile still references).
    @discardableResult
    public static func repair(_ candidate: Candidate, profilesDir: URL,
                              copy: (URL, URL) throws -> Void = { source, destination in
                                  let bytes = try Data(contentsOf: source)
                                  try bytes.write(to: destination, options: .atomic)
                              }) throws -> EntityProfile {
        let source = profilesDir.appendingPathComponent(
            ProfileImageNaming.galleryFileName(for: candidate.profile.id, token: candidate.promote))
        let destination = profilesDir.appendingPathComponent(
            ProfileImageNaming.primaryFileName(for: candidate.profile.id))
        try copy(source, destination)

        var repaired = candidate.profile
        repaired.photoUrl = candidate.promote
        return repaired
    }
}
