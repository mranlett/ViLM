// ActorProfilePhotoFixAll.swift
// "Fix All Actor Profile Photos" — reconciles every actor's primary photo
// against the files that are ACTUALLY in `.catalog/profiles`.
//
// 🚨 WHY THIS EXISTS RATHER THAN MORE OF `ActorProfilePhotoRepair`. That type
// asks `galleryUrls` which photos a performer has and hashes each token to a
// filename. Over a real library that returned nothing for 460 performers with
// missing profile photos, and the reason is that the token is not the file:
// a token rewritten by a re-key, dropped from the array by a merge, or simply
// never recorded leaves its FILE sitting on disk, fully usable, and
// unreachable by anything that starts from the array.
//
// ⭐ So this starts from the DIRECTORY. `<safeId>.jpg` is the primary and
// `<safeId>_*.jpg` are that performer's other photos, whatever any array says
// about them — see `ProfileImageNaming`, which owns that convention. A file is
// evidence; an array entry is a claim about a file.
//
// ⚠️ NEVER GOES ONLINE. The operator's rule stands: "We do not go online to
// display the profile images once downloaded from an initial online sourcing."
// A performer with no local photo at all is REPORTED as such, never fetched.
// That count is the point as much as the repairs are — it is the difference
// between "nothing was broken" and "nothing could be fixed from here", which
// is precisely what the previous silent version could not tell anyone.
//
// 🚨 A WORKING PRIMARY IS NEVER TOUCHED. R4's three stacked bugs were about a
// starred photo being silently reassigned; this pass inherits that boundary
// exactly. `<safeId>.jpg` present means done, whatever `photoUrl` says.

import Foundation

public enum ActorProfilePhotoFixAll {

    /// The file to promote, and what `photoUrl` should say afterwards.
    public struct Promotion: Equatable, Sendable {
        /// A file that already exists in `.catalog/profiles`.
        public let sourceFileName: String
        /// ⭐ The gallery token when the file could be traced back to one, so
        /// `photoUrl` keeps naming the photo's origin. Otherwise the
        /// `local://primary` sentinel — the honest answer for a file whose
        /// remote source is no longer known, and the value `ProfileImageNaming`
        /// already defines for exactly that case. Never a URL that was guessed.
        public let newPhotoUrl: String

        public init(sourceFileName: String, newPhotoUrl: String) {
            self.sourceFileName = sourceFileName
            self.newPhotoUrl = newPhotoUrl
        }
    }

    /// What this pass would do about one performer.
    public enum Outcome: Equatable, Sendable {
        /// `<safeId>.jpg` is present. Nothing to do, nothing to risk.
        case alreadyFine
        /// A local photo exists and can become the primary.
        case promote(Promotion)
        /// The primary is missing and this performer has NO photo on disk.
        /// ⚠️ Reported, never fetched.
        case noLocalSource
    }

    /// Decides one performer's outcome from the directory listing alone.
    ///
    /// ⭐ PURE, and takes the filenames rather than a URL, so the whole rule is
    /// testable without a disk — and so the caller can list the directory once
    /// for the entire library instead of once per performer.
    ///
    /// - Parameter existingFiles: every filename present in `.catalog/profiles`.
    public static func plan(for profile: EntityProfile,
                            existingFiles: Set<String>) -> Outcome {
        let primaryName = ProfileImageNaming.primaryFileName(for: profile.id)
        if existingFiles.contains(primaryName) { return .alreadyFine }

        // 1. A file whose token is still known — preferred, because it lets
        //    `photoUrl` go on naming where the photo came from.
        //    ⚠️ `galleryUrls` order is the operator's order; the first one
        //    with bytes wins, exactly as the narrower repair chose.
        for token in profile.galleryUrls where token != ProfileImageNaming.localPrimaryToken {
            let fileName = ProfileImageNaming.galleryFileName(for: profile.id, token: token)
            if existingFiles.contains(fileName) {
                return .promote(Promotion(sourceFileName: fileName, newPhotoUrl: token))
            }
        }

        // 2. Any other photo this performer has on disk. 🚨 This is the case
        //    the array-driven version could not see at all: the bytes are
        //    there and usable, and only the mapping back to a token is lost.
        //    ⚠️ Sorted, so a performer with several orphans gets the same photo
        //    every run rather than whatever the filesystem happened to list
        //    first — a repair that picks differently each time is not a repair.
        let prefix = ProfileImageNaming.galleryFilePrefix(for: profile.id)
        if let orphan = existingFiles.filter({ $0.hasPrefix(prefix) }).sorted().first {
            return .promote(Promotion(sourceFileName: orphan,
                                      newPhotoUrl: ProfileImageNaming.localPrimaryToken))
        }

        return .noLocalSource
    }

    /// What a whole run did, in terms that can be checked against the library.
    ///
    /// ⚠️ Every performer lands in exactly one bucket, so the four numbers sum
    /// to the number considered — the same discipline `SidecarBackfillSummary`
    /// keeps, and for the same reason: a summary reporting only successes lets
    /// a run that did almost nothing read like a run that did everything.
    public struct Summary: Equatable, Sendable {
        /// The primary photo was already present.
        public var alreadyFine = 0
        /// A local photo was promoted to primary.
        public var repaired = 0
        /// 🚨 Broken, and NOTHING on disk to repair it with. The number that
        /// says whether this tool can help at all — if it is large, the photos
        /// were never downloaded and no local-only pass will ever fix them.
        public var noLocalSource = 0
        /// Attempted and failed: the copy or the database write did not go
        /// through. ⚠️ Distinct from `noLocalSource`, which is not a failure.
        public var failed = 0

        /// Photos fetched because they were recorded but had no file.
        ///
        /// ⚠️ Counted in PHOTOS, not performers, and deliberately outside
        /// `considered`: one performer can contribute a dozen. Mixing the two
        /// units into one total is how a summary stops adding up.
        public var photosDownloaded = 0
        /// Entries removed because the photo is definitively gone (404/410).
        public var entriesDropped = 0
        /// 🚨 Entries KEPT despite failing to download — the source was
        /// unreachable, rate-limiting, or erroring. Reported so a run against a
        /// bad connection is visible as such rather than looking like a library
        /// full of dead links.
        public var entriesUnavailable = 0

        public init() {}

        public var considered: Int { alreadyFine + repaired + noLocalSource + failed }
    }

    /// Applies a promotion: copies the chosen file onto the primary filename
    /// and returns the updated profile.
    ///
    /// ⭐ Copies, never moves — the source file may still be listed in the
    /// performer's gallery, and moving it would delete a photo to fix a
    /// pointer. The same reasoning `ActorProfilePhotoRepair.repair` records.
    ///
    /// - Parameter copy: test seam, as elsewhere in this package.
    public static func apply(_ promotion: Promotion, to profile: EntityProfile,
                             profilesDir: URL,
                             copy: (URL, URL) throws -> Void = { source, destination in
                                 let bytes = try Data(contentsOf: source)
                                 try bytes.write(to: destination, options: .atomic)
                             }) throws -> EntityProfile {
        try copy(profilesDir.appendingPathComponent(promotion.sourceFileName),
                 profilesDir.appendingPathComponent(
                    ProfileImageNaming.primaryFileName(for: profile.id)))

        var fixed = profile
        fixed.photoUrl = promotion.newPhotoUrl
        return fixed
    }

    /// Every filename directly inside `.catalog/profiles`.
    ///
    /// ⚠️ Shallow and non-recursive by design, and an unreadable directory
    /// yields an EMPTY set rather than throwing: a library with no profiles
    /// directory yet is a library where nothing can be repaired, which is a
    /// finding this pass reports rather than an error it fails on.
    public static func existingFileNames(in profilesDir: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: profilesDir.path)) ?? []
        return Set(contents)
    }
}

// MARK: - Making "local or absent" true

public extension ActorProfilePhotoFixAll {

    /// One recorded URL that has no file, and where its file belongs.
    struct MissingPhoto: Equatable, Sendable {
        public let token: String
        public let fileName: String
        /// Whether this token is the profile's `photoUrl` — which lands at the
        /// primary filename and is what a card actually shows.
        public let isPrimary: Bool

        public init(token: String, fileName: String, isPrimary: Bool) {
            self.token = token
            self.fileName = fileName
            self.isPrimary = isPrimary
        }
    }

    /// Every recorded photo for this performer that has no file on disk.
    ///
    /// 🚨 This is the third state enumerated. A gallery entry is a CLAIM that a
    /// photo exists; a file is the photo. Everything returned here is a claim
    /// the library cannot currently support, and the caller's job is to make it
    /// true (download it) or remove it (it is definitively gone).
    ///
    /// ⭐ The primary comes FIRST, because it is the one a card actually shows:
    /// a run that is cancelled half way should have restored faces, not filled
    /// galleries behind them.
    ///
    /// ⚠️ The `local://primary` sentinel is skipped — it names the primary file
    /// rather than a remote photo, so there is nothing to fetch for it.
    static func missingPhotos(for profile: EntityProfile,
                              existingFiles: Set<String>) -> [MissingPhoto] {
        var out: [MissingPhoto] = []
        var seen = Set<String>()

        let primaryToken = profile.photoUrl ?? ""
        if !primaryToken.isEmpty, primaryToken != ProfileImageNaming.localPrimaryToken {
            let fileName = ProfileImageNaming.primaryFileName(for: profile.id)
            if !existingFiles.contains(fileName) {
                out.append(MissingPhoto(token: primaryToken, fileName: fileName, isPrimary: true))
            }
            seen.insert(primaryToken)
        }

        for token in profile.galleryUrls
        where token != ProfileImageNaming.localPrimaryToken && seen.insert(token).inserted {
            let fileName = ProfileImageNaming.galleryFileName(for: profile.id, token: token)
            if !existingFiles.contains(fileName) {
                out.append(MissingPhoto(token: token, fileName: fileName, isPrimary: false))
            }
        }
        return out
    }

    /// Removes tokens whose photos are definitively gone, so the profile stops
    /// claiming photos that do not exist anywhere.
    ///
    /// 🚨 ONLY `.gone` tokens. An `.unavailable` one is kept — see
    /// `ActorPhotoFetch.classify` for why the bar is that high.
    ///
    /// ⚠️ If `photoUrl` was among them it is cleared rather than repointed at
    /// another entry. Choosing a replacement here would be a second, hidden
    /// expression of "which photo is the primary" — `plan(for:existingFiles:)`
    /// owns that decision, and it runs against the files that then exist.
    /// Returns nil when nothing changed, so callers write only real changes.
    static func dropping(_ goneTokens: Set<String>,
                         from profile: EntityProfile) -> EntityProfile? {
        guard !goneTokens.isEmpty else { return nil }

        let remaining = profile.galleryUrls.filter { !goneTokens.contains($0) }
        let primaryIsGone = (profile.photoUrl).map { goneTokens.contains($0) } ?? false
        guard remaining.count != profile.galleryUrls.count || primaryIsGone else { return nil }

        var updated = profile
        updated.galleryUrls = remaining
        if primaryIsGone { updated.photoUrl = nil }
        return updated
    }
}
