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
    /// 🚨 ONE QUESTION PER FILE: does it exist? This was built on
    /// `ActorPhotoScanner.measure` — the duplicate-photo scanner's
    /// reconciliation — on the reasoning that reusing it beat a second
    /// expression of "does this token's file exist". The reasoning was right
    /// and the choice was wrong: `measure` answers a far more expensive
    /// question than this one asks. Per photo it reads the entire file into
    /// memory, opens it twice through `CGImageSource`, renders a thumbnail and
    /// takes a SHA-256 of the full bytes — all to compute content and
    /// perceptual hashes that decide DUPLICATION, which this function does not
    /// ask about and immediately discards. Over a library of ~1,400 performers
    /// with several photos each that is thousands of image decodes, and this
    /// worklist runs on every open of the Get More Photos screen. The screen
    /// looked frozen, and it was: it was hashing the photo library to find out
    /// which files were there.
    ///
    /// ⚠️ The token→filename mapping below mirrors `measure`'s EXACTLY, so this
    /// stays a change of cost and not of meaning:
    ///   - the primary filename is probed only when `photoUrl` is non-empty,
    ///     because `measure` marks a token primary by `photoUrl == token` and
    ///     an empty `photoUrl` equals nothing;
    ///   - a gallery entry equal to `photoUrl` maps to the primary file, which
    ///     has already been ruled absent, so it is skipped rather than probed
    ///     again under a hashed name.
    ///
    /// ⚠️ A profile whose ONLY gallery entry is the `local://primary`
    /// sentinel, with no other photo downloaded, correctly produces no
    /// candidate here even when broken: that sentinel is a placeholder for
    /// the primary file itself, and there are no real bytes at the hashed
    /// gallery filename its literal string produces. That is the honest
    /// answer — nothing local is left to recover — not a bug in this function.
    ///
    /// - Parameter fileExists: test seam, in the style of `RelocationMover`'s.
    public static func worklist(
        _ profiles: [EntityProfile], profilesDir: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [Candidate] {
        profiles.compactMap { profile in
            let primaryToken = profile.photoUrl ?? ""
            let primaryFile = profilesDir.appendingPathComponent(
                ProfileImageNaming.primaryFileName(for: profile.id))
            // The primary already resolves to a file on disk — nothing broken.
            if !primaryToken.isEmpty, fileExists(primaryFile) { return nil }

            // The first gallery photo that was actually downloaded, in
            // `galleryUrls` order — the same one `measure` would have surfaced
            // first, for the same reason.
            for token in profile.galleryUrls where token != primaryToken {
                let file = profilesDir.appendingPathComponent(
                    ProfileImageNaming.galleryFileName(for: profile.id, token: token))
                if fileExists(file) { return Candidate(profile: profile, promote: token) }
            }
            // Nothing local to promote — cannot repair without going online.
            return nil
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
