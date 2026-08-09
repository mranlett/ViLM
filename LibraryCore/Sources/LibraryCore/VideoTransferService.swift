// VideoTransferService.swift
// Moves videos between two libraries and finds byte-identical duplicates
// across them. A move carries the video's whole package: file + full metadata
// + scene markers + cached visuals (poster/contact sheet/marker previews are
// copied, preserving a custom-chosen poster) + its duplicate-scan
// fingerprint. Actors are the deliberate exception: their profiles/photos are
// COPIED (both libraries keep them — an actor only leaves a library when the
// user explicitly deletes it). Every destructive step is ordered copy ->
// verify-by-hash -> write metadata -> only then delete the source, so an
// interrupted or failed transfer never loses the original.

import Foundation
import AVFoundation
import CryptoKit

/// The size/duration signature used to find *candidate* duplicates cheaply,
/// before the expensive content-hash confirmation.
public struct VideoFingerprint: Sendable, Equatable {
    public let assetId: UUID
    public let sizeBytes: Int64
    /// Rounded seconds; nil when the duration couldn't be read.
    public let durationSeconds: Int?

    public init(assetId: UUID, sizeBytes: Int64, durationSeconds: Int?) {
        self.assetId = assetId
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
    }
}

/// A candidate cross-library duplicate: one asset from each side that share
/// exact byte size and (when both are known) rounded duration. NOT yet
/// confirmed identical — the caller must compare content hashes before
/// treating it as a true duplicate.
public struct DuplicateCandidatePair: Sendable, Equatable {
    public let sideAAssetId: UUID
    public let sideBAssetId: UUID
    public let sizeBytes: Int64
    public init(sideAAssetId: UUID, sideBAssetId: UUID, sizeBytes: Int64) {
        self.sideAAssetId = sideAAssetId
        self.sideBAssetId = sideBAssetId
        self.sizeBytes = sizeBytes
    }
}

public enum VideoTransferError: Error {
    case sourceFileMissing
    case copyVerificationFailed
}

/// The result of a single move. A move only reaches this point once the
/// destination copy is fully written and verified; `sourceRemoved` reports
/// whether the source cleanup that follows also succeeded (a false value with
/// a `warning` means the video now exists in *both* libraries and the source
/// should be removed by hand).
public struct VideoMoveOutcome: Sendable {
    public let newAssetId: UUID
    public let destinationRelativePath: String
    public let sourceRemoved: Bool
    public let warning: String?
    /// Actor profiles inserted or enriched in the destination as a side
    /// effect of moving this video, and how many of their photos were newly
    /// copied across.
    public let actorsTransferred: Int
    public let actorPhotosTransferred: Int
}

public final class VideoTransferService {
    public init() {}

    // Session cache of file content hashes, keyed by path + size + mtime so
    // an edit-in-place (trim/flip) can never satisfy a lookup with the
    // pre-edit hash. Today every call site builds a fresh service per
    // operation, but path-only keying was correct only *because* of that —
    // cheap insurance against a future shared instance (DEFECT_INVENTORY L10).
    private var hashCache: [String: String] = [:]
    private let hashLock = NSLock()

    private static func hashCacheKey(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(url.path)|\(size)|\(mtime)"
    }

    // Verification hook for the copy-verify step: given the freshly-written
    // destination copy, returns the hash compared against the source's. Split
    // out as an injectable seam purely so a test can force a verification
    // mismatch (proving the source is preserved when verify fails) without
    // corrupting a real file. Defaults to the real streaming SHA-256 of the
    // copy, so production behavior is exactly as if this were inlined.
    var copyVerificationHash: (URL) throws -> String = { try VideoTransferService.streamingSHA256(of: $0) }

    // MARK: - Content hashing

    /// SHA-256 of a file's bytes, streamed in chunks so multi-GB videos never
    /// load fully into memory. Cached per path for the session.
    public func contentHash(of url: URL) throws -> String {
        let key = Self.hashCacheKey(for: url)
        hashLock.lock()
        if let cached = hashCache[key] {
            hashLock.unlock()
            return cached
        }
        hashLock.unlock()

        let hash = try Self.streamingSHA256(of: url)

        hashLock.lock()
        hashCache[key] = hash
        hashLock.unlock()
        return hash
    }

    private static func streamingSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MB
        while true {
            // Each `read` returns an autoreleased Data. Draining a pool per
            // chunk keeps peak memory at ~one chunk instead of letting
            // thousands of 1 MB buffers accumulate while hashing a multi-GB
            // file — which otherwise jetsam-kills the app on iOS.
            let finished: Bool = try autoreleasepool {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { return true }
                hasher.update(data: chunk)
                return false
            }
            if finished { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Duplicate matching (pure)

    /// Pairs each side-A video with side-B videos sharing its exact byte size
    /// and — when both durations are known — its rounded duration. These are
    /// candidates only; confirm with `contentHash` before deleting anything.
    /// Pure and side-effect free (unit-tested).
    public static func duplicateCandidates(
        sideA: [VideoFingerprint],
        sideB: [VideoFingerprint]
    ) -> [DuplicateCandidatePair] {
        var bBySize: [Int64: [VideoFingerprint]] = [:]
        for b in sideB where b.sizeBytes > 0 {
            bBySize[b.sizeBytes, default: []].append(b)
        }

        var pairs: [DuplicateCandidatePair] = []
        for a in sideA where a.sizeBytes > 0 {
            guard let sameSize = bBySize[a.sizeBytes] else { continue }
            for b in sameSize {
                // If both durations are known they must match; if either is
                // unknown, size alone keeps it as a (weaker) candidate — the
                // content-hash confirmation is the real gate either way.
                if let da = a.durationSeconds, let db = b.durationSeconds, da != db {
                    continue
                }
                pairs.append(DuplicateCandidatePair(
                    sideAAssetId: a.assetId,
                    sideBAssetId: b.assetId,
                    sizeBytes: a.sizeBytes
                ))
            }
        }
        return pairs
    }

    /// Reads a video's rounded duration, or nil if it can't be determined.
    public static func videoDurationSeconds(_ url: URL) async -> Int? {
        let avAsset = AVURLAsset(url: url)
        guard let duration = try? await avAsset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int(seconds.rounded())
    }

    public static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    // MARK: - Move

    /// Copies `asset`'s video (and sidecar) from `sourceLibrary` into
    /// `destinationLibrary`, verifies the copy by SHA-256, writes the full
    /// metadata + scene markers, regenerates thumbnails, and only then deletes
    /// the source. On any failure *before* the source delete, the partial
    /// destination copy is rolled back and the error rethrown — the source is
    /// always left intact until the destination is complete and verified.
    public func moveVideo(
        _ asset: Asset,
        from sourceLibrary: URL,
        to destinationLibrary: URL
    ) async throws -> VideoMoveOutcome {
        let fm = FileManager.default
        let sourceVideoURL = sourceLibrary.appendingPathComponent(asset.relativePath)
        guard fm.fileExists(atPath: sourceVideoURL.path) else {
            throw VideoTransferError.sourceFileMissing
        }

        // Captured up front so the duplicate-scan fingerprint can be carried
        // to the destination after the move (its cache is keyed by size+mtime).
        let sourceAttrs = try? fm.attributesOfItem(atPath: sourceVideoURL.path)
        let sourceSize = sourceAttrs?[.size] as? Int64
        let sourceMtime = (sourceAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970

        let sourceHash = try contentHash(of: sourceVideoURL)

        // A non-colliding relative path in the destination (don't overwrite an
        // unrelated file that happens to share the path).
        let destinationRelativePath = Self.availableRelativePath(
            preferred: asset.relativePath, in: destinationLibrary
        )
        let destinationVideoURL = destinationLibrary.appendingPathComponent(destinationRelativePath)
        try fm.createDirectory(
            at: destinationVideoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Copy to a temp path first; promote to the real path only after the
        // hash verifies, so a partial/corrupt copy never appears as the video.
        let tempURL = destinationVideoURL.appendingPathExtension("vilmtmp")
        try? fm.removeItem(at: tempURL)
        try fm.copyItem(at: sourceVideoURL, to: tempURL)

        let newAssetId = UUID()
        var actorsTransferred = 0
        var actorPhotosTransferred = 0
        do {
            let copyHash = try copyVerificationHash(tempURL)
            guard copyHash == sourceHash else {
                throw VideoTransferError.copyVerificationFailed
            }
            try? fm.removeItem(at: destinationVideoURL)
            try fm.moveItem(at: tempURL, to: destinationVideoURL)

            // Sidecar JSON, if any (best effort — not fatal).
            let sourceSidecar = sourceVideoURL.deletingPathExtension().appendingPathExtension("json")
            if fm.fileExists(atPath: sourceSidecar.path) {
                let destSidecar = destinationVideoURL.deletingPathExtension().appendingPathExtension("json")
                try? fm.copyItem(at: sourceSidecar, to: destSidecar)
            }

            // Full metadata into the destination under a fresh id.
            //
            // ⚠️ EVERY field, including the match. This rebuild previously
            // omitted the release date and the whole enrichment group, so
            // moving a video between libraries silently discarded a confirmed
            // match — the destination then re-searched by name and re-guessed.
            // See AssetPreservationTests.testFieldCountIsPinned, which lists
            // this as a copy site.
            let newAsset = Asset(
                id: newAssetId,
                relativePath: destinationRelativePath,
                fileName: asset.fileName,
                status: asset.status,
                createdAt: asset.createdAt,
                tags: asset.tags,
                externalLink: asset.externalLink,
                notes: asset.notes,
                // ⚠️ Carried with its provenance. A description moved to
                // another library without the source that wrote it becomes
                // indistinguishable from something the operator typed.
                sourceDescription: asset.sourceDescription,
                sourceDescriptionFrom: asset.sourceDescriptionFrom,
                sourceDescriptionAt: asset.sourceDescriptionAt,
                rating: asset.rating,
                videoName: asset.videoName,
                seasonNumber: asset.seasonNumber,
                episodeNumber: asset.episodeNumber,
                episode: asset.episode,
                releaseDate: asset.releaseDate,
                enrichmentState: asset.enrichmentState,
                enrichmentSource: asset.enrichmentSource,
                enrichmentSourceId: asset.enrichmentSourceId,
                lookupRoute: asset.lookupRoute,
                enrichmentUrl: asset.enrichmentUrl,
                enrichmentCheckedAt: asset.enrichmentCheckedAt,
                playCount: asset.playCount,
                lastPlayedAt: asset.lastPlayedAt
            )
            let destinationStore = try LibraryStore(at: destinationLibrary)
            try destinationStore.insertAsset(newAsset)

            // Cached visuals travel WITH the video (they're part of its
            // package): copy the existing poster, contact sheet, and marker
            // previews rather than regenerating — which also preserves a
            // user-chosen "Set as Main Thumbnail" poster. Generation is only
            // the fallback for a visual the source never had.
            let destinationSheets = ContactSheetService(store: destinationStore)
            for subdir in ["thumbnails", "contactSheets", "markers"] {
                try? fm.createDirectory(
                    at: destinationLibrary.appendingPathComponent(".catalog/\(subdir)"),
                    withIntermediateDirectories: true)
            }
            func carryVisual(_ subdir: String, from oldName: String, to newName: String) -> Bool {
                let src = sourceLibrary.appendingPathComponent(".catalog/\(subdir)/\(oldName)")
                let dst = destinationLibrary.appendingPathComponent(".catalog/\(subdir)/\(newName)")
                guard fm.fileExists(atPath: src.path) else { return false }
                try? fm.removeItem(at: dst)
                return (try? fm.copyItem(at: src, to: dst)) != nil
            }

            // Scene markers -> new ids referencing the new asset; each
            // preview image is copied across under its new marker id.
            let sourceStore = try LibraryStore(at: sourceLibrary)
            let markers = (try? sourceStore.fetchSceneMarkers(for: asset.id)) ?? []
            for marker in markers {
                let newMarker = SceneMarker(
                    id: UUID(),
                    assetId: newAssetId,
                    timestampSeconds: marker.timestampSeconds,
                    label: marker.label,
                    createdAt: marker.createdAt
                )
                try destinationStore.saveSceneMarker(newMarker)
                if !carryVisual("markers", from: "\(marker.id.uuidString).jpg", to: "\(newMarker.id.uuidString).jpg") {
                    try? await destinationSheets.generateMarkerThumbnail(
                        for: newAsset,
                        markerId: newMarker.id,
                        timestampSeconds: newMarker.timestampSeconds,
                        libraryURL: destinationLibrary
                    )
                }
            }

            // Poster thumbnail + contact sheet: copy, generate only if absent.
            if !carryVisual("thumbnails", from: "\(asset.id.uuidString).jpg", to: "\(newAssetId.uuidString).jpg") {
                try? await destinationSheets.generateSingleThumbnail(for: newAsset, libraryURL: destinationLibrary)
            }
            if !carryVisual("contactSheets", from: "\(asset.id.uuidString).jpg", to: "\(newAssetId.uuidString).jpg") {
                try? await destinationSheets.generateContactSheet(for: newAsset, libraryURL: destinationLibrary)
            }

            // The duplicate-scan fingerprint travels too (re-keyed to the
            // destination path and the copied file's own size/mtime), so the
            // destination's next Find Duplicates scan doesn't re-decode this
            // video. Best-effort — the cache is regenerable.
            if let sourceSize, let sourceMtime {
                let srcPrints = FrameFingerprintStore(libraryURL: sourceLibrary)
                if let hashes = srcPrints.validHashes(
                        relativePath: asset.relativePath, sizeBytes: sourceSize, modified: sourceMtime),
                   let destAttrs = try? fm.attributesOfItem(atPath: destinationVideoURL.path),
                   let destSize = destAttrs[.size] as? Int64 {
                    let destMtime = (destAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    var destPrints = FrameFingerprintStore(libraryURL: destinationLibrary)
                    destPrints.setHashes(hashes, relativePath: destinationRelativePath,
                                         sizeBytes: destSize, modified: destMtime)
                    destPrints.save()
                }
            }

            // Bring this video's actors' profile data and photos across too, so
            // the destination's actor info is never stale relative to a moved
            // video. Reuses the standalone Actor Library Merge semantics
            // (source scalar fields win on a match; photos are additive and
            // deduplicated by content hash; unreferenced actors untouched),
            // scoped to just this video's actors. Best-effort: the video and
            // its metadata have already moved, so a hiccup enriching actors
            // isn't worth aborting the move over (a later merge would catch it).
            // 🚨 Resolved against the SOURCE library, whose ids these are used
            // to filter. After the re-key a name-form string matches no uid, so
            // this set would be non-empty, select nothing, and report zero
            // actors transferred on every move — a silent loss of exactly the
            // profile data this block exists to carry across.
            // ⚠️ Built per move, and that is a real cost on a batch: each one
            // reads the source library's whole profile table. Acceptable only
            // because a move is already dominated by copying and hashing the
            // video file itself — a resolver over ~1,800 rows is noise beside
            // a multi-gigabyte streaming SHA-256. If moves are ever batched
            // without a file copy, hoist this to the caller.
            let sourceResolver = NodeResolver(
                profiles: (try? sourceStore.fetchAllEntityProfiles()) ?? [])
            let actorIds = Set(asset.actors.compactMap {
                sourceResolver.localId(for: "actor:\($0)")
            })
            if !actorIds.isEmpty,
               let actorExport = try? sourceStore.exportActorLibrary(onlyActorIds: actorIds),
               let mergeResult = try? destinationStore.applyActorMerge(actorExport) {
                actorsTransferred = mergeResult.newActorCount + mergeResult.updatedActorCount
                actorPhotosTransferred = mergeResult.newPhotoCount
            }

            // ⚠️ The studios and tags this video's edges will point AT.
            //
            // Actors were already carried; studios and tag records were not,
            // because before the graph existed the destination only needed the
            // text. An edge points at a row, so without these the video arrives
            // and silently cannot be connected to its own studio or tags.
            //
            // Only what is MISSING is written. A destination profile is the
            // richer one whenever it already exists — it has been enriched in
            // that library — and overwriting it with the source's copy would
            // trade information for uniformity.
            for name in Set(asset.studios) where !name.isEmpty {
                // 🚨 Both ends resolved by NAME, not by a shared id. Two
                // libraries mint different uids for the same studio, so an
                // id-keyed check would find nothing in the destination and
                // then copy the SOURCE's uid across as a key — the duplicate
                // this project's federation rule exists to prevent.
                let alreadyThere = try? destinationStore.fetchEntityProfile(named: name,
                                                                            type: "studio")
                let fromSource = try? sourceStore.fetchEntityProfile(named: name,
                                                                     type: "studio")
                if alreadyThere == nil, let profile = fromSource ?? nil {
                    // ⚠️ Written under an id the DESTINATION mints. A sender's
                    // key is evidence about which node is meant, never a value
                    // to store.
                    let localId = (try? destinationStore.newEntityProfile(
                        named: name, type: "studio").id) ?? profile.id
                    try? destinationStore.saveEntityProfile(profile.renamed(to: localId))
                }
            }
            if !asset.actions.isEmpty {
                let wanted = Set(asset.actions.map(TagNormalizer.identityKey))
                let existing = Set((try? destinationStore.fetchTagVocabulary())?
                    .map(\.identityKey) ?? [])
                for record in (try? sourceStore.fetchTagVocabulary()) ?? []
                where wanted.contains(record.identityKey) && !existing.contains(record.identityKey) {
                    try? destinationStore.saveTagRecord(record)
                }
            }

            // The video takes its place in the destination's graph.
            //
            // Best-effort like the rest of this block: the video and its text
            // have already moved intact, and a failure here costs a re-run of
            // Connect the Graph rather than any data.
            _ = try? destinationStore.connectEdges(forVideo: newAssetId)
        } catch {
            // Roll the destination back so a failed move leaves no orphan.
            try? fm.removeItem(at: tempURL)
            try? fm.removeItem(at: destinationVideoURL)
            let destSidecar = destinationVideoURL.deletingPathExtension().appendingPathExtension("json")
            try? fm.removeItem(at: destSidecar)
            throw error
        }

        // Destination is complete and verified. Remove the source; if that
        // fails, the move still succeeded — report it as a warning so the
        // stray source copy can be cleaned up by hand.
        var sourceRemoved = true
        var warning: String?
        do {
            try deleteVideoAndArtifacts(asset, in: sourceLibrary, toTrash: true)
        } catch {
            sourceRemoved = false
            warning = "Copied to the destination, but couldn't remove the source copy: \(error.localizedDescription)"
        }

        return VideoMoveOutcome(
            newAssetId: newAssetId,
            destinationRelativePath: destinationRelativePath,
            sourceRemoved: sourceRemoved,
            warning: warning,
            actorsTransferred: actorsTransferred,
            actorPhotosTransferred: actorPhotosTransferred
        )
    }

    // MARK: - Deletion (source cleanup + duplicate reconciliation)

    // Seam for the video-file removal step, purely so a test can force a
    // removal failure (proving the DB row survives it) without fighting
    // filesystem permissions. Defaults to the real removal, so production
    // behavior is exactly as if this were inlined.
    var fileRemover: (URL, Bool) throws -> Void = { try VideoTransferService.removeFile($0, toTrash: $1) }

    /// Fully removes a video from a library. Ordering is deliberate
    /// (DEFECT_INVENTORY C2): the **video file is removed first** — if that
    /// fails (unmounted volume, revoked scope, permissions) the method throws
    /// with the catalog untouched, so the video's metadata and markers are
    /// never lost while its file lives on. Only after the file is gone do the
    /// artifacts and the DB row (which cascade-deletes marker rows) go.
    /// The video file and sidecar go to the Trash when `toTrash` is true and
    /// the platform supports it; catalog artifacts are always removed outright.
    public func deleteVideoAndArtifacts(_ asset: Asset, in libraryURL: URL, toTrash: Bool) throws {
        let fm = FileManager.default
        let store = try LibraryStore(at: libraryURL)
        let sheets = ContactSheetService(store: store)

        // 1. The gating step: the video file itself. A throw here aborts with
        //    the database fully intact.
        let videoURL = libraryURL.appendingPathComponent(asset.relativePath)
        try fileRemover(videoURL, toTrash)

        // 2. Best-effort artifacts (all regenerable or orphan-only).
        let sidecarURL = videoURL.deletingPathExtension().appendingPathExtension("json")
        if fm.fileExists(atPath: sidecarURL.path) {
            try? Self.removeFile(sidecarURL, toTrash: toTrash)
        }
        // Marker preview thumbnails must go before the DB rows cascade away
        // (their ids are unrecoverable afterwards).
        let markers = (try? store.fetchSceneMarkers(for: asset.id)) ?? []
        for marker in markers {
            sheets.deleteMarkerThumbnail(markerId: marker.id, libraryURL: libraryURL)
        }
        let thumbURL = libraryURL.appendingPathComponent(".catalog/thumbnails/\(asset.id.uuidString).jpg")
        let sheetURL = libraryURL.appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg")
        try? fm.removeItem(at: thumbURL)
        try? fm.removeItem(at: sheetURL)
        // The video's duplicate-scan fingerprint leaves with it (best-effort;
        // a missed removal is only a dead cache entry, pruned on next scan).
        var prints = FrameFingerprintStore(libraryURL: libraryURL)
        prints.removeEntry(relativePath: asset.relativePath)
        prints.save()

        // 3. The DB row last (one transaction with its playlist memberships
        //    in THIS library — no dangling entries for same-library deletes;
        //    cross-library playlist references are display-tolerated instead).
        //    If this throws after the file is gone, the row points at a
        //    missing file — Check for Changes flags it normally, which is
        //    recoverable (unlike the reverse order's metadata loss).
        try store.performInTransaction { db in
            try store.removePlaylistEntries(assetId: asset.id, in: db)
            try store.deleteAsset(asset, in: db)
        }
    }

    private static func removeFile(_ url: URL, toTrash: Bool) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        if toTrash {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                // Fall through to a hard delete if trashing isn't supported
                // (e.g. some external/network volumes).
            }
        }
        try fm.removeItem(at: url)
    }

    // MARK: - Helpers

    /// Returns `preferred` if nothing exists at that path in `library`,
    /// otherwise the same name with a numeric suffix before the extension.
    static func availableRelativePath(preferred: String, in library: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: library.appendingPathComponent(preferred).path) {
            return preferred
        }
        let ext = (preferred as NSString).pathExtension
        let base = (preferred as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !fm.fileExists(atPath: library.appendingPathComponent(candidate).path) {
                return candidate
            }
            n += 1
        }
    }
}
