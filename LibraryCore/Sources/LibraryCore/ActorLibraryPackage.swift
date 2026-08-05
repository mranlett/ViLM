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
    /// Entities this library deliberately removed.
    ///
    /// Defaulted rather than required so an export written before v20 decodes
    /// as "no deletions known" instead of failing — and, more importantly, so
    /// an old file is never read as "everything was deleted".
    public var tombstones: [EntityTombstone] = []

    public init(formatVersion: Int, exportedAt: Date, profiles: [EntityProfile],
                photos: [ExportedPhoto], tombstones: [EntityTombstone] = []) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
        self.photos = photos
        self.tombstones = tombstones
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        profiles = try c.decode([EntityProfile].self, forKey: .profiles)
        photos = try c.decode([ExportedPhoto].self, forKey: .photos)
        tombstones = (try? c.decode([EntityTombstone].self, forKey: .tombstones)) ?? []
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
    /// - Parameter includingPhotoData: when false, photo entries carry their
    ///   content hash but NOT their bytes.
    ///
    ///   Planning a sync compares photos by hash and never reads `data`, but a
    ///   full export materialises every JPEG in the library into memory at
    ///   once — measured at 2.3 GB across 7,761 files on one real library, and
    ///   a plan snapshots EVERY library, so two of those were resident
    ///   simultaneously before the converged export built a third array. That
    ///   is what crashed the sync screen. Metadata-only snapshots read each
    ///   file to hash it and then let it go.
    public func exportActorLibrary(onlyActorIds: Set<String>? = nil,
                                   includingPhotoData: Bool = true) throws -> ActorLibraryExport {
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
            var primaryExported = false
            if let data = try? Data(contentsOf: primaryURL) {
                exportedFileNames.insert(primaryFileName)
                primaryExported = true
                photos.append(ExportedPhoto(
                    actorId: profile.id, isPrimary: true, sourceToken: profile.photoUrl,
                    contentHash: ProfileImageNaming.sha256Hex(data), fileExtension: "jpg",
                    data: includingPhotoData ? data : Data()
                ))
            }

            for token in profile.galleryUrls {
                // The local sentinel is never portable.
                guard token != ProfileImageNaming.localPrimaryToken else { continue }

                // The photoUrl token is normally skipped here because the
                // primary FILE already carried it. When that file is absent it
                // must NOT be skipped: the image still exists on disk under its
                // gallery name, and skipping it made the photo invisible to
                // this library's exports while every other library could see
                // it. The plan then reported the gap on every pass, the merge
                // wrote the file again under the same unexportable name, and
                // the actor could never converge — with no error anywhere.
                if primaryExported, token == profile.photoUrl { continue }

                let fileName = ProfileImageNaming.galleryFileName(for: profile.id, token: token)
                guard !exportedFileNames.contains(fileName) else { continue }
                let fileURL = profilesDir.appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                exportedFileNames.insert(fileName)
                photos.append(ExportedPhoto(
                    actorId: profile.id,
                    // Standing in for a missing primary file, so the
                    // destination can adopt it as one.
                    isPrimary: !primaryExported && token == profile.photoUrl,
                    sourceToken: token,
                    contentHash: ProfileImageNaming.sha256Hex(data), fileExtension: "jpg",
                    data: includingPhotoData ? data : Data()
                ))
            }
        }

        // Tombstones are NOT filtered by `onlyActorIds`: a deletion the caller
        // did not think to ask about is still a deletion, and dropping it here
        // would let a scoped sync resurrect what a full one removed.
        let tombstones = (try? fetchTombstones()) ?? []

        return ActorLibraryExport(formatVersion: ActorLibraryExport.currentFormatVersion,
                                  exportedAt: Date(), profiles: actorProfiles,
                                  photos: photos, tombstones: tombstones)
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

        // Deletions the source recorded, applied BEFORE the profile loop so an
        // incoming record cannot re-create what the same export says was
        // removed.
        var deletedByTombstone = Set<String>()
        for tombstone in export.tombstones {
            let existing = try EntityProfile.fetchOne(db, key: tombstone.entityId)
            if TombstoneRules.shouldPropagate(tombstone: tombstone, to: existing) {
                _ = try EntityProfile.deleteOne(db, key: tombstone.entityId)
            }
            // Carried forward whether or not this library held a copy: a third
            // library must learn of the deletion from this one too.
            try recordTombstone(tombstone, in: db)

            // Refusing the incoming copy is a SEPARATE question from deleting a
            // local one. A library that already removed the entity has nothing
            // to delete, but the converged export still carries the record from
            // whichever library has yet to catch up — and importing it would
            // undo the deletion using the very sync meant to carry it.
            let incoming = export.profiles.first { $0.id == tombstone.entityId }
            if TombstoneRules.suppressesImport(tombstone: tombstone, incoming: incoming) {
                deletedByTombstone.insert(tombstone.entityId)
            }
        }

        for imported in export.profiles where !deletedByTombstone.contains(imported.id) {
            let existing = existingProfiles[imported.id]
            let existingHashes = existing.map { Self.existingPhotoHashes(for: $0, profilesDir: profilesDir) } ?? []
            let incomingPhotos = photosByActor[imported.id] ?? []

            var mergedGalleryUrls = existing?.galleryUrls ?? []
            var mergedPhotoUrl = existing?.photoUrl

            for photo in incomingPhotos {
                // A metadata-only export (see `includingPhotoData`) carries
                // hashes without bytes. Writing one would replace a real photo
                // with a zero-byte file, so such entries are never applied.
                guard !photo.data.isEmpty else { continue }
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
                } else if photo.isPrimary, mergedPhotoUrl == primaryToken,
                          !FileManager.default.fileExists(atPath: profilesDir
                            .appendingPathComponent(ProfileImageNaming.primaryFileName(for: imported.id)).path) {
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
                    // `local://primary` names THIS library's own primary slot.
                    // It is not a portable identity, and storing it as a
                    // GALLERY token in another library is a trap: the export
                    // filter deliberately skips that token, so the photo would
                    // never appear in this library's exports, every future plan
                    // would see the same gap, and the sync would offer the same
                    // actors forever without ever converging. Content-address
                    // it instead, exactly as an untokened photo is handled.
                    //
                    // The same applies to a token that collides with THIS
                    // library's primary: reaching here with such a token means
                    // the primary file already exists holding different bytes
                    // (two libraries used one token for two images). Storing
                    // this photo under that token would make the export skip it
                    // as "already covered by the primary", and the two hashes
                    // would never converge in either direction.
                    var token = photo.sourceToken ?? "imported-photo://\(photo.contentHash)"
                    if token == ProfileImageNaming.localPrimaryToken || token == mergedPhotoUrl {
                        token = "imported-photo://\(photo.contentHash)"
                    }
                    var fileURL = profilesDir.appendingPathComponent(
                        ProfileImageNaming.galleryFileName(for: imported.id, token: token))

                    // The gallery filename is derived from the token, so a
                    // token already holding DIFFERENT bytes here means two
                    // libraries used one URL for two images. The write below is
                    // guarded on the file's absence, so without this the
                    // incoming photo is silently dropped — and since it is
                    // genuinely absent from this library (checked against
                    // existingHashes above), the plan asks for it again on
                    // every pass and never converges.
                    if FileManager.default.fileExists(atPath: fileURL.path),
                       let occupying = try? Data(contentsOf: fileURL),
                       ProfileImageNaming.sha256Hex(occupying) != photo.contentHash {
                        token = "imported-photo://\(photo.contentHash)"
                        fileURL = profilesDir.appendingPathComponent(
                            ProfileImageNaming.galleryFileName(for: imported.id, token: token))
                    }

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
            // One rule for "which side's enrichment result is current", shared
            // with the federated merge so the two cannot disagree. With no
            // existing row both sides are the import, which returns the import.
            // Repair for libraries already carrying the bad token from earlier
            // merges: a gallery entry of `local://primary` is only meaningful
            // when this profile's primary IS the local one. Otherwise it is
            // unresolvable — the export skips it and the gallery shows a hole.
            if mergedPhotoUrl != ProfileImageNaming.localPrimaryToken {
                mergedGalleryUrls.removeAll { $0 == ProfileImageNaming.localPrimaryToken }
            }

            let newerEnrichment = MergeSemantics.newerChecked(imported, existing ?? imported)

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
                ageAtCareerStart: imported.ageAtCareerStart ?? existing?.ageAtCareerStart,
                // Enrichment state (v18). The MORE RECENT check wins rather
                // than the usual coalesce: this records when a lookup last ran,
                // so an older result must not mask a newer one.
                enrichmentState: newerEnrichment.enrichmentState,
                enrichmentSource: newerEnrichment.enrichmentSource,
                enrichmentSourceId: newerEnrichment.enrichmentSourceId ?? existing?.enrichmentSourceId,
                enrichmentCheckedAt: newerEnrichment.enrichmentCheckedAt,
                links: EntityLink.merged(existing?.links ?? [], adding: imported.links)
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

    // isGalleryToken was removed. Its rule — "skip the token that equals
    // photoUrl" — was correct only when a primary FILE existed to carry that
    // token's image, and it was applied unconditionally. Where the file was
    // absent the photo became unexportable, and the sync could never converge.
    // Both call sites now decide with the file's presence in hand.

    // coalesce/union moved to the shared `MergeSemantics` (reused by the
    // full-library restore-over-existing merge).

    /// Content hashes of every photo file currently cached on disk for this
    /// profile (primary + gallery), used to detect duplicates on import.
    private static func existingPhotoHashes(for profile: EntityProfile, profilesDir: URL) -> Set<String> {
        var hashes = Set<String>()

        let primaryURL = profilesDir.appendingPathComponent(ProfileImageNaming.primaryFileName(for: profile.id))
        var primaryFound = false
        if let data = try? Data(contentsOf: primaryURL) {
            hashes.insert(ProfileImageNaming.sha256Hex(data))
            primaryFound = true
        }

        for token in profile.galleryUrls {
            guard token != ProfileImageNaming.localPrimaryToken else { continue }
            // Mirrors the export rule: with no primary file, the photoUrl
            // token's image lives under its gallery name and is a real file
            // this library holds. Missing it here would make an import treat an
            // already-present photo as new.
            if primaryFound, token == profile.photoUrl { continue }
            let fileURL = profilesDir.appendingPathComponent(ProfileImageNaming.galleryFileName(for: profile.id, token: token))
            if let data = try? Data(contentsOf: fileURL) {
                hashes.insert(ProfileImageNaming.sha256Hex(data))
            }
        }

        return hashes
    }
}
