// ActorLibraryPackage.swift
// Actor Library Merge: the .vilmactors export format (profiles + photo bytes)
// and the plan/apply merge into a destination library. The merge is
// non-destructive and field-level: a real source value wins on a conflict,
// but a nil/empty source field never overwrites a populated destination one;
// tags/AKAs are unioned; photos are additive and deduplicated by content hash.

import Foundation
import GRDB

/// A single photo file bundled with an actor library export. `sourceToken` is
/// the original `galleryUrls` entry (or `photoUrl`) this photo corresponds to
/// — nil only for a primary photo that had no URL (a purely local photo).
/// `contentHash` is the SHA-256 of `data` and is the basis for de-duplication
/// on import, since filenames/URLs can differ across libraries even for the
/// same image.
public struct ExportedPhoto: Codable, Sendable {
    public let actorId: String
    public let isPrimary: Bool
    public let sourceToken: String?
    public let contentHash: String
    public let fileExtension: String
    public let data: Data

    public init(actorId: String, isPrimary: Bool, sourceToken: String?, contentHash: String, fileExtension: String, data: Data) {
        self.actorId = actorId
        self.isPrimary = isPrimary
        self.sourceToken = sourceToken
        self.contentHash = contentHash
        self.fileExtension = fileExtension
        self.data = data
    }
}

/// Self-contained package produced by "Export Actor Library For Merge" and
/// consumed by "Import and Merge Actor Library". A single JSON file (base64
/// photo data) rather than a zip — there is no interop requirement since only
/// this app ever reads it, so a plain container keeps this dependency-free.
public struct ActorLibraryExport: Codable, Sendable {
    /// Bumped to 2 for schema v17 (career span + precise birth date).
    ///
    /// Informational only today: no reader validates it, and the importer is
    /// tolerant of missing fields either way, so an older archive restores
    /// unchanged and a newer one loses nothing on an older build. It is here so
    /// that a future reader CAN tell the shapes apart.
    public static let currentFormatVersion = 2

    public let formatVersion: Int
    public let exportedAt: Date
    public let profiles: [EntityProfile]
    public let photos: [ExportedPhoto]

    public init(formatVersion: Int, exportedAt: Date, profiles: [EntityProfile], photos: [ExportedPhoto]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
        self.photos = photos
    }
}

/// Preview of what applying an import would do, for a review-before-commit UI.
public struct ActorMergePlan: Sendable {
    public struct ActorChange: Identifiable, Sendable {
        public var id: String { actorId }
        public let actorId: String
        public let displayName: String
        public let isNew: Bool
        public let newPhotoCount: Int
        public let duplicatePhotoCount: Int
    }

    public let changes: [ActorChange]

    public var newActorCount: Int { changes.filter(\.isNew).count }
    public var updatedActorCount: Int { changes.filter { !$0.isNew }.count }
    public var totalNewPhotos: Int { changes.reduce(0) { $0 + $1.newPhotoCount } }
    public var totalDuplicatePhotos: Int { changes.reduce(0) { $0 + $1.duplicatePhotoCount } }
}

public struct ActorMergeResult: Sendable {
    public let newActorCount: Int
    public let updatedActorCount: Int
    public let newPhotoCount: Int
    public let duplicatePhotoCount: Int
}

extension LibraryStore {

    /// Packages actor profiles plus whichever of their photo files are
    /// actually cached on disk. The primary slot is always checked directly
    /// (independent of `galleryUrls` bookkeeping) so a photo is never missed
    /// due to a metadata quirk.
    ///
    /// Pass `onlyActorIds` to export just a subset (e.g. the actors a single
    /// moved video references); nil exports every actor.
    public func exportActorLibrary(onlyActorIds: Set<String>? = nil) throws -> ActorLibraryExport {
        var actorProfiles = try fetchAllEntityProfiles().filter { $0.id.hasPrefix("actor:") }
        if let onlyActorIds {
            actorProfiles = actorProfiles.filter { onlyActorIds.contains($0.id) }
        }
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")

        var photos: [ExportedPhoto] = []
        for profile in actorProfiles {
            var exportedFileNames = Set<String>()

            let primaryFileName = ProfileImageNaming.primaryFileName(for: profile.id)
            let primaryURL = profilesDir.appendingPathComponent(primaryFileName)
            if let data = try? Data(contentsOf: primaryURL) {
                exportedFileNames.insert(primaryFileName)
                photos.append(ExportedPhoto(
                    actorId: profile.id, isPrimary: true, sourceToken: profile.photoUrl,
                    contentHash: ProfileImageNaming.sha256Hex(data), fileExtension: "jpg", data: data
                ))
            }

            for token in profile.galleryUrls {
                guard Self.isGalleryToken(token, photoUrl: profile.photoUrl) else { continue }
                let fileName = ProfileImageNaming.galleryFileName(for: profile.id, token: token)
                guard !exportedFileNames.contains(fileName) else { continue }
                let fileURL = profilesDir.appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                exportedFileNames.insert(fileName)
                photos.append(ExportedPhoto(
                    actorId: profile.id, isPrimary: false, sourceToken: token,
                    contentHash: ProfileImageNaming.sha256Hex(data), fileExtension: "jpg", data: data
                ))
            }
        }

        return ActorLibraryExport(formatVersion: ActorLibraryExport.currentFormatVersion, exportedAt: Date(), profiles: actorProfiles, photos: photos)
    }

    /// Computes what an import would do without writing anything.
    public func planActorMerge(_ export: ActorLibraryExport) throws -> ActorMergePlan {
        let existingProfiles = Dictionary(uniqueKeysWithValues: try fetchAllEntityProfiles().map { ($0.id, $0) })
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        let photosByActor = Dictionary(grouping: export.photos, by: \.actorId)

        var changes: [ActorMergePlan.ActorChange] = []
        for profile in export.profiles {
            let existing = existingProfiles[profile.id]
            let existingHashes = existing.map { Self.existingPhotoHashes(for: $0, profilesDir: profilesDir) } ?? []
            let incoming = photosByActor[profile.id] ?? []

            let newCount = incoming.filter { !existingHashes.contains($0.contentHash) }.count
            let dupCount = incoming.count - newCount

            changes.append(.init(
                actorId: profile.id,
                displayName: profile.id.hasPrefix("actor:") ? String(profile.id.dropFirst(6)) : profile.id,
                isNew: existing == nil,
                newPhotoCount: newCount,
                duplicatePhotoCount: dupCount
            ))
        }

        changes.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return ActorMergePlan(changes: changes)
    }

    /// Commits an import with a non-destructive, field-level merge: for a
    /// matched actor, a real imported (source) value wins, but a nil/empty
    /// source field keeps the destination's existing value rather than wiping
    /// it; tags/AKAs are unioned; photos are additive only (never removed),
    /// de-duplicated by content hash. Actors absent from the import are
    /// untouched.
    @discardableResult
    public func applyActorMerge(_ export: ActorLibraryExport) throws -> ActorMergeResult {
        try performInTransaction { db in
            try applyActorMerge(export, in: db)
        }
    }

    /// Transaction-scoped variant, for callers composing the actor merge into
    /// a larger atomic operation (the full-library restore-merge). Photo file
    /// writes happen inline — they're additive and content-addressed, so
    /// orphans from a rolled-back transaction are harmless and get rewritten
    /// on retry.
    @discardableResult
    func applyActorMerge(_ export: ActorLibraryExport, in db: Database) throws -> ActorMergeResult {
        let existingProfiles = Dictionary(uniqueKeysWithValues: try fetchAllEntityProfiles(in: db).map { ($0.id, $0) })
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let photosByActor = Dictionary(grouping: export.photos, by: \.actorId)

        var newActorCount = 0, updatedActorCount = 0, newPhotoCount = 0, duplicatePhotoCount = 0

        for imported in export.profiles {
            let existing = existingProfiles[imported.id]
            let existingHashes = existing.map { Self.existingPhotoHashes(for: $0, profilesDir: profilesDir) } ?? []
            let incomingPhotos = photosByActor[imported.id] ?? []

            var mergedGalleryUrls = existing?.galleryUrls ?? []
            var mergedPhotoUrl = existing?.photoUrl

            for photo in incomingPhotos {
                if existingHashes.contains(photo.contentHash) {
                    duplicatePhotoCount += 1
                    continue
                }

                let primaryToken = photo.sourceToken ?? ProfileImageNaming.localPrimaryToken

                if photo.isPrimary, mergedPhotoUrl == nil {
                    // Destination has no primary yet — adopt this one.
                    let fileURL = profilesDir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: imported.id))
                    try photo.data.write(to: fileURL)
                    mergedPhotoUrl = primaryToken
                    if !mergedGalleryUrls.contains(primaryToken) { mergedGalleryUrls.append(primaryToken) }
                } else if photo.isPrimary, mergedPhotoUrl == primaryToken {
                    // Destination already REFERENCES this photo as its
                    // primary, but the file is missing on disk (token lists
                    // can sync ahead of files — a metadata-only merge, or a
                    // restore whose photos didn't survive). Restore the file.
                    let fileURL = profilesDir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: imported.id))
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        try photo.data.write(to: fileURL)
                    }
                    if !mergedGalleryUrls.contains(primaryToken) { mergedGalleryUrls.append(primaryToken) }
                } else {
                    // Fold in as an additional gallery photo. Photos with no
                    // portable URL (purely local) get a deterministic synthetic
                    // token derived from their content hash, so re-imports are
                    // idempotent. The FILE write is gated on the file's
                    // existence, NOT on token membership: a destination whose
                    // galleryUrls already lists this token (metadata synced
                    // before the files did) must still receive the missing
                    // file — this exact gap silently skipped every photo copy
                    // when actor records were already identical across
                    // libraries.
                    let token = photo.sourceToken ?? "imported-photo://\(photo.contentHash)"
                    let fileURL = profilesDir.appendingPathComponent(ProfileImageNaming.galleryFileName(for: imported.id, token: token))
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        try photo.data.write(to: fileURL)
                    }
                    if !mergedGalleryUrls.contains(token) { mergedGalleryUrls.append(token) }
                }
                newPhotoCount += 1
            }

            // Field-level merge, NOT wholesale overwrite: the imported
            // (source) value wins when it's actually present, but a nil/empty
            // source value never clobbers a populated destination value —
            // otherwise merging a sparsely-filled actor from one library wipes
            // richer bio data in the other. Tags/AKAs are unioned so neither
            // side loses any; photos are already additive above.
            let merged = EntityProfile(
                id: imported.id,
                bio: MergeSemantics.coalesce(imported.bio, existing?.bio),
                photoUrl: mergedPhotoUrl,
                homePage: MergeSemantics.coalesce(imported.homePage, existing?.homePage),
                gender: MergeSemantics.coalesce(imported.gender, existing?.gender),
                hairColor: MergeSemantics.coalesce(imported.hairColor, existing?.hairColor),
                birthYear: imported.birthYear ?? existing?.birthYear,
                countryOfOrigin: MergeSemantics.coalesce(imported.countryOfOrigin, existing?.countryOfOrigin),
                rating: imported.rating ?? existing?.rating,
                tags: MergeSemantics.union(imported.tags, existing?.tags ?? []),
                galleryUrls: mergedGalleryUrls,
                akas: MergeSemantics.union(imported.akas, existing?.akas ?? []),
                createdAt: existing?.createdAt ?? imported.createdAt,
                // Career span (v17), same non-destructive rule: an incoming
                // value fills a blank but never clobbers a populated one.
                // Omitting these would silently drop career data on every
                // library merge.
                birthDate: MergeSemantics.coalesce(imported.birthDate, existing?.birthDate),
                careerSpanRaw: MergeSemantics.coalesce(imported.careerSpanRaw, existing?.careerSpanRaw),
                careerStartYear: imported.careerStartYear ?? existing?.careerStartYear,
                careerEndYear: imported.careerEndYear ?? existing?.careerEndYear,
                ageAtCareerStart: imported.ageAtCareerStart ?? existing?.ageAtCareerStart
            )
            try saveEntityProfile(merged, in: db)

            if existing == nil { newActorCount += 1 } else { updatedActorCount += 1 }
        }

        return ActorMergeResult(
            newActorCount: newActorCount,
            updatedActorCount: updatedActorCount,
            newPhotoCount: newPhotoCount,
            duplicatePhotoCount: duplicatePhotoCount
        )
    }

    private static func isGalleryToken(_ token: String, photoUrl: String?) -> Bool {
        token != photoUrl && token != ProfileImageNaming.localPrimaryToken
    }

    // coalesce/union moved to the shared `MergeSemantics` (reused by the
    // full-library restore-over-existing merge).

    /// Content hashes of every photo file currently cached on disk for this
    /// profile (primary + gallery), used to detect duplicates on import.
    private static func existingPhotoHashes(for profile: EntityProfile, profilesDir: URL) -> Set<String> {
        var hashes = Set<String>()

        let primaryURL = profilesDir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: profile.id))
        if let data = try? Data(contentsOf: primaryURL) {
            hashes.insert(ProfileImageNaming.sha256Hex(data))
        }

        for token in profile.galleryUrls {
            guard isGalleryToken(token, photoUrl: profile.photoUrl) else { continue }
            let fileURL = profilesDir.appendingPathComponent(ProfileImageNaming.galleryFileName(for: profile.id, token: token))
            if let data = try? Data(contentsOf: fileURL) {
                hashes.insert(ProfileImageNaming.sha256Hex(data))
            }
        }

        return hashes
    }
}
