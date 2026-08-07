// LibraryStore.swift
// The SQLite (GRDB) persistence layer: one cached connection per library, and
// the core CRUD for assets, entity profiles, tombstones, smart collections and
// the tag vocabulary.
//
// ⚠️ This type is deliberately split across several files. It reached 2,769
// lines on 2026-08-07 and was still growing — a dozen commits in one session
// touched it — at which point "where does this belong" had no answer and every
// change landed at the bottom.
//
//   LibraryStore+Migrations.swift   the schema, version by version
//   LibraryStore+Graph.swift        strings → edges, and reading BOTH at once
//   LibraryStore+GraphEdges.swift   the edge tables and the questions asked of them
//   LibraryStore+Collections.swift  playlists and scene markers
//
// The split is by SUBJECT, not by size: each file holds one invariant that its
// methods share. Adding a method means asking which invariant it belongs to,
// which is a question with an answer.

import Foundation
import GRDB

public class LibraryStore {
    /// ⚠️ `internal`, not `private`, and deliberately so.
    ///
    /// `private` is FILE-scoped in Swift, and this type is now split across
    /// several files by subject — so a private connection would mean every
    /// method that touches SQLite had to live in one 2,769-line file, which is
    /// exactly the problem the split exists to solve.
    ///
    /// ⭐ The protection that matters is unchanged: `internal` is
    /// MODULE-scoped, so the app target still cannot reach the database. The
    /// rule was never "one file owns the connection" — it was "the UI never
    /// touches SQLite directly, it asks LibraryCore", and that still holds.
    let dbQueue: DatabaseQueue
    public let libraryURL: URL

    // Opening a fresh SQLite connection and running the migrator on every
    // `LibraryStore(at:)` is expensive, and the app constructs stores ad hoc
    // in dozens of places (per rating tap, tag edit, fetch, …). Cache one
    // connection per database path: subsequent stores for the same library
    // reuse it and skip migration. A shared connection also avoids
    // "database is locked" errors from multiple connections contending.
    // Access is serialized by cacheLock, so opt out of Swift 6's global-state
    // isolation check.
    nonisolated(unsafe) private static var queueCache: [String: DatabaseQueue] = [:]
    private static let cacheLock = NSLock()

    /// Drops cached connections for every library except the one at
    /// `activeURL` (pass nil to drop them all). Without this, switching
    /// between libraries accumulates an open SQLite connection (plus WAL
    /// file handles) per library visited, for the life of the app. Existing
    /// `LibraryStore` instances keep their own reference to an evicted
    /// queue, so in-flight work is unaffected — the connection closes once
    /// the last such instance goes away.
    ///
    /// For anything narrower than a library *switch* (or test teardown), use
    /// `evictCachedConnection(forLibraryAt:)` instead — sweeping the whole
    /// cache mid-session lets the next store open a *second* connection to a
    /// file that in-flight background work still writes through, restoring
    /// the multi-connection "database is locked" contention the cache exists
    /// to prevent (DEFECT_INVENTORY H6).
    public static func evictCachedConnections(keepingLibraryAt activeURL: URL?) {
        evictCachedConnections(keeping: activeURL.map { [$0] } ?? [])
    }

    /// Set-based variant for the multi-library session: on a primary switch,
    /// every library that remains OPEN (primary + attachments) keeps its
    /// shared connection; everything else is dropped.
    public static func evictCachedConnections(keeping activeURLs: Set<URL>) {
        let keepPaths = Set(activeURLs.map {
            $0.appendingPathComponent(".catalog").appendingPathComponent("catalog.sqlite").path
        })
        cacheLock.lock()
        defer { cacheLock.unlock() }
        queueCache = queueCache.filter { keepPaths.contains($0.key) }
    }

    /// Drops the cached connection for exactly one library. This is the
    /// eviction backup/restore code should use: it targets the scratch
    /// library it created (so WAL file handles close before the scratch
    /// directory is deleted) without touching the active library's shared
    /// connection.
    public static func evictCachedConnection(forLibraryAt url: URL) {
        let path = url.appendingPathComponent(".catalog").appendingPathComponent("catalog.sqlite").path
        cacheLock.lock()
        defer { cacheLock.unlock() }
        queueCache.removeValue(forKey: path)
    }

    public init(at url: URL) throws {
        self.libraryURL = url
        let dbPath = url.appendingPathComponent(".catalog").appendingPathComponent("catalog.sqlite").path

        LibraryStore.cacheLock.lock()
        defer { LibraryStore.cacheLock.unlock() }

        if let cached = LibraryStore.queueCache[dbPath] {
            self.dbQueue = cached
            return
        }

        let catalogURL = url.appendingPathComponent(".catalog")
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        let config: Configuration = {
            var c = Configuration()
            // If a second connection to the same file does appear (an evicted
            // queue still held by in-flight work while a new one opens),
            // briefly wait out the other writer's lock instead of surfacing
            // an immediate "database is locked" error (DEFECT_INVENTORY H6).
            c.busyMode = .timeout(5)
            c.prepareDatabase { db in
                // WAL improves write throughput (fewer fsyncs) and allows a
                // read to proceed during a write. SQLite silently keeps the
                // prior mode if the filesystem can't support WAL, so this is
                // safe on network/USB volumes.
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                // SQLite does not enforce foreign keys unless told to, per
                // connection. This is what makes scene_markers' ON DELETE
                // CASCADE actually take effect when a video is deleted.
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            return c
        }()

        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        self.dbQueue = queue
        try migrate()
        LibraryStore.queueCache[dbPath] = queue
    }



    // MARK: - Tombstones

    public func fetchTombstones() throws -> [EntityTombstone] {
        try dbQueue.read { db in try EntityTombstone.fetchAll(db) }
    }

    func recordTombstone(_ tombstone: EntityTombstone, in db: Database) throws {
        // A repeated deletion refreshes the timestamp rather than erroring: the
        // most recent removal is the one that should win against a stale copy.
        try tombstone.save(db)
    }

    public func recordTombstone(_ tombstone: EntityTombstone) throws {
        try dbQueue.write { db in try recordTombstone(tombstone, in: db) }
    }

    /// Clears a tombstone, for when an entity is deliberately re-created.
    func clearTombstone(for entityId: String, in db: Database) throws {
        _ = try EntityTombstone.deleteOne(db, key: entityId)
    }

    /// Merges the write-ahead log back into the main database file and truncates
    /// it, so a copy of `catalog.sqlite` taken right after is complete on its own
    /// (no `-wal` sidecar needed). Used before a backup so the archived database
    /// is consistent.
    public func checkpointWAL() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Writes a consistent, self-contained snapshot of this library's database
    /// to `destinationURL` using SQLite's online backup API — safe even while
    /// concurrent writes are in flight (the engine copies a single committed
    /// state), unlike file-copying a live `catalog.sqlite` + WAL, which can
    /// tear (DEFECT_INVENTORY H2). The snapshot is integrity-checked before
    /// returning, so a backup built from it can't silently archive corruption.
    public func snapshotDatabase(to destinationURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        var destQueue: DatabaseQueue? = try DatabaseQueue(path: destinationURL.path)
        try dbQueue.backup(to: destQueue!)
        // The page-level copy carries the source's persistent WAL journal
        // mode, which would leave live -wal/-shm sidecars next to the
        // snapshot. Convert to DELETE mode (checkpoints the WAL into the main
        // file), close the connection, then drop any sidecar files SQLite's
        // close left behind — they're redundant after the conversion. Result:
        // one truly self-contained file.
        try destQueue!.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try Self.runIntegrityCheck(on: destQueue!)
        destQueue = nil
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: destinationURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: destinationURL.path + "-shm"))
    }

    /// Runs `PRAGMA integrity_check` and throws unless SQLite reports "ok".
    public func runIntegrityCheck() throws {
        try Self.runIntegrityCheck(on: dbQueue)
    }

    private static func runIntegrityCheck(on queue: DatabaseQueue) throws {
        let result = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        guard result == "ok" else {
            throw DatabaseError(resultCode: .SQLITE_CORRUPT,
                                message: "integrity_check failed: \(result ?? "no result")")
        }
    }

    // MARK: - Transactions

    /// Runs `body` inside a single database transaction: every write in it
    /// commits together or rolls back together. This is what makes multi-record
    /// operations (restore-merge, batch imports) atomic instead of N
    /// independent transactions. Internal because it hands out the GRDB
    /// `Database` handle; inside `body`, use the `(…, in: db)` method variants —
    /// the plain public methods each open their own transaction and must NOT be
    /// called from within `body` (GRDB connections are not reentrant).
    func performInTransaction<T>(_ body: (Database) throws -> T) throws -> T {
        try dbQueue.write(body)
    }

    // MARK: - Smart Collections

    public func fetchAllSmartCollections() throws -> [SmartCollection] {
        try dbQueue.read { db in
            try fetchAllSmartCollections(in: db)
        }
    }

    func fetchAllSmartCollections(in db: Database) throws -> [SmartCollection] {
        try SmartCollection.order(Column("createdAt").asc).fetchAll(db)
    }

    public func saveSmartCollection(_ collection: SmartCollection) throws {
        try dbQueue.write { db in
            try saveSmartCollection(collection, in: db)
        }
    }

    func saveSmartCollection(_ collection: SmartCollection, in db: Database) throws {
        try collection.save(db)
    }
    
    public func deleteSmartCollection(id: String) throws {
        try dbQueue.write { db in
            _ = try SmartCollection.deleteOne(db, key: id)
        }
    }

    // MARK: - Tag vocabulary

    public func fetchTagVocabulary() throws -> [TagRecord] {
        try dbQueue.read { db in try TagRecord.fetchAll(db) }
    }

    /// Saves a tag's kind, keyed by its folded identity.
    ///
    /// An upsert rather than an insert: classifying a tag is something an
    /// operator will do more than once, and the second attempt must correct the
    /// first rather than colliding with the unique index.
    public func saveTagRecord(_ record: TagRecord) throws {
        try dbQueue.write { db in try record.save(db) }
    }

    /// Brings the vocabulary up to date with what the library actually uses.
    ///
    /// Additive and idempotent: a tag already known keeps the kind it was given,
    /// and only genuinely new tags arrive — unclassified, on the worklist. A
    /// re-run after classifying must never undo the classification, which is
    /// what a blind replace would do.
    ///
    /// Returns the tags that were newly discovered, so a caller can say "6 new
    /// tags need classifying" rather than leaving them to be noticed.
    @discardableResult
    public func promoteTagVocabulary() throws -> [TagRecord] {
        // ⚠️ Actor profile tags too. `connectAllEdges` reports unknown tags
        // from both places, so promoting from only one of them left the other
        // permanently unreachable — reported by one tool and invisible to the
        // tool that report names as the fix.
        let performerTags = try fetchAllEntityProfiles()
            .filter { $0.id.hasPrefix("actor:") }
            .flatMap(\.tags)
        let discovered = TagVocabulary.promoting(try fetchAllAssets(),
                                                 performerTags: performerTags)
        let known = Set(try fetchTagVocabulary().map(\.identityKey))
        let new = discovered.filter { !known.contains($0.identityKey) }

        try dbQueue.write { db in
            for record in new { try record.insert(db) }
        }
        return new
    }

    /// Performers recorded twice, found by their own alias lists.
    ///
    /// ⚠️ Counts videos across BOTH representations. A profile reachable only
    /// through `video_performer` edges would otherwise read as having none, and
    /// "0 videos" is the strongest argument for merging one away — so getting
    /// it wrong argues for deleting the wrong half.
    public func auditAliasSplits() throws -> [AliasSplitCandidate] {
        let profiles = try fetchAllEntityProfiles().filter { $0.id.hasPrefix("actor:") }

        let edges: [(String, String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT video_id, performer_id FROM video_performer")
                .map { ($0["video_id"], $0["performer_id"]) }
        }
        // ⚠️ A SET of video ids per profile, not a running total. A performer
        // carried by both a tag string and an edge on the same video must count
        // once — adding the two sources would double every migrated profile and
        // make the merge look far more valuable than it is.
        var byProfile: [String: Set<String>] = [:]
        for (videoId, performerId) in edges {
            byProfile[performerId, default: []].insert(videoId)
        }
        for asset in try fetchAllAssets() {
            for name in Set(asset.actors) {
                byProfile["actor:\(name)", default: []].insert(asset.id.uuidString)
            }
        }
        let counts = byProfile.mapValues(\.count)

        return AliasSplitAudit.findings(.init(
            profiles: profiles.map { ($0.id, $0.akas,
                                      $0.enrichmentState == .matched, $0.birthYear) },
            videoCounts: counts))
    }

    /// Profiles nothing refers to, grouped by node kind.
    ///
    /// ⚠️ Gathers the edge sets as well as the strings. A check reading tag
    /// strings alone will propose deleting the library's entire cast the moment
    /// the string-retirement migration runs.
    public func auditOrphans() throws -> [GraphNodeKind: [OrphanFinding]] {
        let profiles = try fetchAllEntityProfiles().map(\.id)
        var referenced = Set<String>()
        for asset in try fetchAllAssets() {
            for tag in asset.tags where GraphNodeKind.of(tag) != nil {
                referenced.insert(tag)
            }
        }
        let (performers, studios, parents): (Set<String>, Set<String>, Set<String>) =
            try dbQueue.read { db in
                (Set(try String.fetchAll(db, sql: "SELECT DISTINCT performer_id FROM video_performer")),
                 Set(try String.fetchAll(db, sql: "SELECT DISTINCT studio_id FROM video_studio")),
                 Set(try String.fetchAll(db, sql:
                    "SELECT DISTINCT parent_studio_id FROM studio_parent WHERE valid_to IS NULL")))
            }

        return OrphanAudit.findings(.init(profiles: profiles,
                                          referencedByString: referenced,
                                          performersWithEdges: performers,
                                          studiosWithEdges: studios,
                                          studiosWithChildren: parents))
    }

    /// Gives every studio the library uses a profile row, so it can be looked
    /// up, confirmed, and eventually drive a folder name.
    ///
    /// Studios were bare strings: 241 of them, and not one had a row. A string
    /// cannot carry an external identity or a lookup verdict, so no studio
    /// could ever be *verified* — which is what the naming convention needs
    /// before it can put one in a folder name.
    ///
    /// Unlike tags, a studio needs no new table: `EntityProfile` already
    /// carries an id, a source, a source id and an enrichment state, and a
    /// studio genuinely has a logo and links worth keeping. Promotion is
    /// therefore additive and costs no schema change.
    ///
    /// Additive and idempotent — an existing profile is never overwritten, so a
    /// re-run cannot undo a match or a correction. Returns what was created.
    /// ⚠️ Queried in SQL, not by decoding the library.
    ///
    /// The first version fetched every `Asset` and every `EntityProfile` to
    /// work this out — 2,104 rows decoded, each parsing a JSON tag array, plus
    /// 1,366 profiles — and it ran on every profile reload, for every attached
    /// library. That is a full library scan on a hot path, and it made the app
    /// unusable with the external drive attached.
    ///
    /// `json_each` gets the distinct studios directly, and the anti-join means
    /// the common case — nothing new — touches almost nothing.
    @discardableResult
    public func promoteStudioProfiles() throws -> [String] {
        let missing: [String] = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT j.value
                FROM assets, json_each(assets.tags) j
                WHERE j.value LIKE 'studio:_%'
                  AND j.value NOT IN (SELECT id FROM entity_profiles)
                ORDER BY j.value
                """)
        }
        guard !missing.isEmpty else { return [] }

        try dbQueue.write { db in
            for id in missing {
                try saveEntityProfile(EntityProfile(id: id), in: db)
            }
        }
        return missing
    }

    /// Records that a studio came from an external source, and is therefore
    /// verified.
    ///
    /// Idempotent and non-destructive: an existing profile keeps everything it
    /// already had — bio, links, a source id from a richer lookup — and only
    /// gains the verdict. A studio already `matched` is left entirely alone, so
    /// re-accepting the same studio on a second video costs a read.
    /// Marks a studio confirmed, recording the source's own id for it.
    ///
    /// 🚨 `sourceId` used to be absent entirely. A studio confirmed as a side
    /// effect of matching a video got its state, its source and a timestamp —
    /// and not the one thing that makes a LATER lookup possible. The value was
    /// available the whole time: the proposal carries `studioSourceId` and the
    /// review already resolves it; it was dropped at this boundary.
    ///
    /// 🚨 That was worse than a missing field, because `StudioBatchPolicy`
    /// skips anything already `.matched` — so the only tool that would have
    /// supplied the id refused to look at those studios. The door closed behind
    /// them. Hence the second change: an already-matched studio with NO id may
    /// still learn one.
    ///
    /// ⚠️ It may never learn a DIFFERENT one. Replacing an id this library
    /// holds would silently re-point a confirmed match at another studio, which
    /// is the overrule every other write path here refuses.
    public func confirmStudio(_ name: String, source: String?,
                              sourceId: String? = nil) throws {
        let id = "studio:\(name)"
        var profile = try fetchEntityProfile(for: id) ?? EntityProfile(id: id)

        let missingId = profile.enrichmentSourceId?.isEmpty ?? true
        if profile.enrichmentState == .matched {
            guard missingId, let sourceId, !sourceId.isEmpty else { return }
            profile.enrichmentSourceId = sourceId
            try saveEntityProfile(profile)
            return
        }

        profile.enrichmentState = .matched
        profile.enrichmentSource = source
        if let sourceId, !sourceId.isEmpty { profile.enrichmentSourceId = sourceId }
        profile.enrichmentCheckedAt = Date()
        try saveEntityProfile(profile)

        // The edge as well as the columns (v31). A studio confirmed as a side
        // effect of matching a video is still a match, and leaving it column-
        // only is how the id went missing on 51 of 62 studios.
        if let sourceId, !sourceId.isEmpty, let source {
            try recordMatch(NodeMatch(nodeId: id, source: source,
                                      sourceId: sourceId, method: .name),
                            isVideo: false)
        }
    }

    public func fetchAllAssets() throws -> [Asset] {
        try dbQueue.read { db in
            // This maps the SQLite rows back into your Swift Asset structs automatically
            try Asset.fetchAll(db)
        }
    }
    
    public func fetchEntityProfile(for id: String) throws -> EntityProfile? {
        try dbQueue.read { db in
            try EntityProfile.fetchOne(db, key: id)
        }
    }
    
    public func fetchAllEntityProfiles() throws -> [EntityProfile] {
        try dbQueue.read { db in
            try fetchAllEntityProfiles(in: db)
        }
    }

    func fetchAllEntityProfiles(in db: Database) throws -> [EntityProfile] {
        try EntityProfile.fetchAll(db)
    }
    
    public func resolveActorAKA(for normalizedName: String) throws -> String {
        let profiles = try fetchAllEntityProfiles()
        for profile in profiles where profile.id.hasPrefix("actor:") {
            let mainName = String(profile.id.dropFirst(6))
            if profile.akas.contains(normalizedName) {
                return mainName
            }
        }
        return normalizedName
    }

    public func deleteEntityProfile(for id: String) throws {
        try dbQueue.write { db in
            _ = try EntityProfile.deleteOne(db, key: id)
            // Recorded so the removal survives a sync. Without this the other
            // library simply copies the profile back.
            try recordTombstone(EntityTombstone(entityId: id), in: db)
        }
    }

    public func saveEntityProfile(_ profile: EntityProfile) throws {
        try dbQueue.write { db in
            try saveEntityProfile(profile, in: db)
        }
    }

    func saveEntityProfile(_ profile: EntityProfile, in db: Database) throws {
        try profile.save(db)
    }

    /// Saves every profile in ONE transaction: all rows commit together or
    /// none do. This is what batch imports (CSV) should use — per-row saves
    /// leave an invisible partial import behind a mid-file failure
    /// (DEFECT_INVENTORY M4).
    public func saveEntityProfiles(_ profiles: [EntityProfile]) throws {
        try performInTransaction { db in
            for profile in profiles {
                try saveEntityProfile(profile, in: db)
            }
        }
    }
    
    /// Filenames under `.catalog/profiles` that belong to the entity with
    /// `oldSafeId`, mapped to their names under `newSafeId`: the primary
    /// ("old.jpg" → "new.jpg") and gallery photos ("old_<hash>.jpg" →
    /// "new_<hash>.jpg"). Unrelated files are excluded. Pure, for testability.
    static func plannedProfileImageRenames(
        fileNames: [String], oldSafeId: String, newSafeId: String
    ) -> [(from: String, to: String)] {
        fileNames.compactMap { name in
            if name == "\(oldSafeId).jpg" {
                return (name, "\(newSafeId).jpg")
            }
            if name.hasPrefix("\(oldSafeId)_") && name.hasSuffix(".jpg") {
                return (name, newSafeId + name.dropFirst(oldSafeId.count))
            }
            return nil
        }
    }

    @discardableResult
    public func renameTagGlobally(oldTag: String, newTag: String) throws -> TagRenameOutcome {
        // 🚨 The old spelling is matched AS STORED, not as normalized.
        //
        // This compared `asset.tags[i] == normalize(oldTag)`, so renaming the
        // lowercase `tag:pov` looked for `tag:Pov` and matched nothing — while
        // the caller reported success. That is the whole point of a
        // case-collision cleanup: the losing spelling is by definition the one
        // that is NOT canonical, so normalizing it before the search removed
        // exactly the rows the tool existed to find.
        let normalizedOld = TagNormalizer.normalize(fullTag: oldTag)

        // ⭐ The chosen spelling is written unchanged. See `tidied`: normalizing
        // here overruled the operator's answer — a case-only repair normalized
        // to the SAME string and returned below having done nothing at all.
        let normalizedNew = TagNormalizer.tidied(fullTag: newTag)

        // Only a genuine no-op returns early. The old test compared NORMALIZED
        // forms, so `pov` → `Pov` was read as "nothing to do" and every
        // case-only repair silently did nothing.
        if oldTag == normalizedNew { return TagRenameOutcome(videosChanged: 0,
                                                             profileMoved: false,
                                                             vocabularyRespelled: false) }

        // Move the entity's photo files BEFORE the DB commit, with rollback
        // (DEFECT_INVENTORY M1): the old order committed the rename first and
        // then moved files with swallowed errors, so any failure left the
        // renamed profile pointing at filenames that no longer match — photos
        // silently vanished from the UI. Now a failed move aborts with the
        // catalog untouched, and a failed DB write moves the files back;
        // either way disk and database agree, and errors reach the caller.
        let oldSafeId = normalizedOld.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let newSafeId = normalizedNew.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        var performedMoves: [(from: URL, to: URL)] = []
        // A destination file that already exists means the merge target owns
        // that photo slot (same content token). The merged row keeps the
        // destination's file, so the source becomes unreferenced — but it's
        // only safe to delete once the DB commit has actually happened.
        var collidingSources: [URL] = []
        let rollbackMoves = {
            for (from, to) in performedMoves.reversed() {
                try? FileManager.default.moveItem(at: to, to: from)
            }
        }
        if FileManager.default.fileExists(atPath: profilesDir.path) {
            let names = try FileManager.default.contentsOfDirectory(atPath: profilesDir.path)
            for move in Self.plannedProfileImageRenames(fileNames: names, oldSafeId: oldSafeId, newSafeId: newSafeId) {
                let from = profilesDir.appendingPathComponent(move.from)
                let to = profilesDir.appendingPathComponent(move.to)
                if FileManager.default.fileExists(atPath: to.path) {
                    collidingSources.append(from)
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                    performedMoves.append((from, to))
                } catch {
                    rollbackMoves()
                    throw error
                }
            }
        }

        let outcome: TagRenameOutcome
        do {
            outcome = try renameTagInDatabase(oldTag: oldTag,
                                              normalizedOld: normalizedOld,
                                              normalizedNew: normalizedNew)
        } catch {
            rollbackMoves()
            throw error
        }

        // Committed: remove the now-unreferenced colliding sources rather
        // than leaving invisible orphans on disk.
        for url in collidingSources {
            try? FileManager.default.removeItem(at: url)
        }
        return outcome
    }

    @discardableResult
    private func renameTagInDatabase(oldTag: String, normalizedOld: String,
                                     normalizedNew: String) throws -> TagRenameOutcome {
        var videosChanged = 0, profileMoved = false, vocabularyRespelled = false
        try dbQueue.write { db in
            let assets = try Asset.fetchAll(db)
            for var asset in assets {
                var modified = false
                for i in 0..<asset.tags.count {
                    // ⚠️ Case-insensitive, and against the tag AS THE CALLER
                    // NAMED IT. The audit's own premise is that spellings
                    // differing only by case are one tag — the filters already
                    // compare that way — so the repair must find them all,
                    // whatever casing each row happens to hold.
                    if TagNormalizer.isSameTag(asset.tags[i], oldTag)
                        || asset.tags[i] == normalizedOld {
                        asset.tags[i] = normalizedNew
                        modified = true
                    }
                }
                if modified {
                    videosChanged += 1
                    // Deduplicate tags while preserving order
                    var uniqueTags = [String]()
                    for t in asset.tags {
                        if !uniqueTags.contains(t) {
                            uniqueTags.append(t)
                        }
                    }
                    asset.tags = uniqueTags
                    try asset.update(db)
                }
            }
            
            // 🚨 The tag VOCABULARY, which this rename never touched.
            //
            // `tags` carries the spelling everything displays, keyed by a folded
            // identity. Rewriting the strings on the videos and leaving the
            // vocabulary alone meant a spelling repair changed nothing the
            // operator could see — the old spelling came straight back from the
            // vocabulary — which is most of why the tool looked broken.
            if let value = Self.tagValue(of: normalizedNew),
               let oldValue = Self.tagValue(of: normalizedOld) {
                let oldKey = TagNormalizer.identityKey(oldValue)
                let newKey = TagNormalizer.identityKey(value)

                if var record = try TagRecord.fetchOne(db, key: oldKey) {
                    if oldKey == newKey {
                        // A case-only repair: same tag, new spelling. The
                        // identity is unchanged, so every edge still points at
                        // the right row and only the display name moves.
                        record.displayName = value
                        try record.update(db)
                        vocabularyRespelled = true
                    } else {
                        // ⚠️ A different tag entirely, so the EDGES must move
                        // too — `video_tag`, `performer_tag` and the staging
                        // table all key on the identity. Leaving them behind
                        // would strand every edge on a vocabulary row that no
                        // longer exists.
                        //
                        // `OR IGNORE` then `DELETE`: where the destination edge
                        // already exists the update would collide on the primary
                        // key, and the correct result is one edge, not an error.
                        // ⚠️ The destination vocabulary row FIRST. The edge
                        // tables have a foreign key onto `tags`, so moving an
                        // edge to an identity that does not exist yet fails the
                        // constraint — which is the correct behaviour and the
                        // reason the order matters rather than being tidy.
                        if var destination = try TagRecord.fetchOne(db, key: newKey) {
                            // The destination keeps its own kind; an
                            // unclassified destination may learn one.
                            if destination.kind == nil, record.kind != nil {
                                destination.kind = record.kind
                                try destination.update(db)
                            }
                        } else {
                            var moved = TagRecord(displayName: value)
                            moved.kind = record.kind
                            try moved.insert(db)
                        }
                        for table in ["video_tag", "performer_tag", "pending_tag_association"] {
                            try db.execute(sql:
                                "UPDATE OR IGNORE \(table) SET tag_id = ? WHERE tag_id = ?",
                                arguments: [newKey, oldKey])
                            try db.execute(sql: "DELETE FROM \(table) WHERE tag_id = ?",
                                           arguments: [oldKey])
                        }
                        _ = try record.delete(db)
                        vocabularyRespelled = true
                    }
                }
            }

            // Handle Entity Profile merging
            if let oldProfile = try EntityProfile.fetchOne(db, key: normalizedOld) {
                if var dest = try EntityProfile.fetchOne(db, key: normalizedNew) {
                    // Destination already has a profile: merge instead of
                    // discarding the source. The destination's own values win
                    // where set; the source fills gaps, and list fields are
                    // unioned so no bio/photo/AKA data is silently lost.
                    dest.bio = dest.bio ?? oldProfile.bio
                    dest.photoUrl = dest.photoUrl ?? oldProfile.photoUrl
                    dest.homePage = dest.homePage ?? oldProfile.homePage
                    dest.gender = dest.gender ?? oldProfile.gender
                    dest.hairColor = dest.hairColor ?? oldProfile.hairColor
                    dest.birthYear = dest.birthYear ?? oldProfile.birthYear
                    dest.countryOfOrigin = dest.countryOfOrigin ?? oldProfile.countryOfOrigin
                    dest.rating = dest.rating ?? oldProfile.rating
                    dest.tags = (dest.tags + oldProfile.tags.filter { !dest.tags.contains($0) })
                    dest.galleryUrls = (dest.galleryUrls + oldProfile.galleryUrls.filter { !dest.galleryUrls.contains($0) })
                    dest.akas = (dest.akas + oldProfile.akas.filter { !dest.akas.contains($0) })
                    // Career span (v17), enrichment result (v18) and links
                    // (v19). Omitting these discarded every enriched field the
                    // moment two actors were merged by a rename.
                    dest.birthDate = dest.birthDate ?? oldProfile.birthDate
                    dest.careerSpanRaw = dest.careerSpanRaw ?? oldProfile.careerSpanRaw
                    dest.careerStartYear = dest.careerStartYear ?? oldProfile.careerStartYear
                    dest.careerEndYear = dest.careerEndYear ?? oldProfile.careerEndYear
                    dest.ageAtCareerStart = dest.ageAtCareerStart ?? oldProfile.ageAtCareerStart
                    dest.enrichmentState = dest.enrichmentState ?? oldProfile.enrichmentState
                    dest.enrichmentSource = dest.enrichmentSource ?? oldProfile.enrichmentSource
                    dest.enrichmentSourceId = dest.enrichmentSourceId ?? oldProfile.enrichmentSourceId
                    dest.enrichmentCheckedAt = dest.enrichmentCheckedAt ?? oldProfile.enrichmentCheckedAt
                    dest.links = EntityLink.merged(dest.links, adding: oldProfile.links)
                    try dest.save(db)
                } else {
                    // Safe to rename the profile. `renamed(to:)` owns the field
                    // list so this site cannot fall behind the model again —
                    // spelling it out here is what dropped AKAs, then career
                    // span, then enrichment state and links.
                    try oldProfile.renamed(to: normalizedNew).save(db)
                }

                // 🚨 Move the GRAPH EDGES before the old profile goes.
                //
                // `video_performer`, `performer_tag`, `video_studio` and
                // `studio_parent` all reference `entity_profiles` with
                // ON DELETE CASCADE — so deleting the old row does not orphan
                // those edges, it DESTROYS them. Renaming or merging an actor
                // silently wiped every cast edge they had, and merging two
                // studios wiped the hierarchy along with them. The tag strings
                // on the videos were rewritten, so browsing still looked right
                // and only the graph was gone.
                //
                // ⚠️ `OR IGNORE` then `DELETE`, exactly as the tag tables above:
                // where the destination edge already exists the update collides
                // on the primary key, and one edge is the correct result.
                // ⚠️ `entity_match` is in this list because v31 added it with
                // the same ON DELETE CASCADE. Omitting it would mean merging
                // two profiles discarded the identity one of them had just been
                // confirmed with — the exact defect this loop was written to
                // fix, recurring on a table added afterwards.
                for (table, column) in [("video_performer", "performer_id"),
                                        ("performer_tag", "performer_id"),
                                        ("video_studio", "studio_id"),
                                        ("studio_parent", "studio_id"),
                                        ("studio_parent", "parent_studio_id"),
                                        ("entity_match", "entity_id")] {
                    try db.execute(sql:
                        "UPDATE OR IGNORE \(table) SET \(column) = ? WHERE \(column) = ?",
                        arguments: [normalizedNew, normalizedOld])
                    try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ?",
                                   arguments: [normalizedOld])
                }
                // ⚠️ A merge can make a studio its own parent — if the losing
                // studio was a child of the winner, remapping both columns
                // points the row at itself. Left in place it is a cycle the
                // hierarchy refuses everywhere else.
                try db.execute(sql:
                    "DELETE FROM studio_parent WHERE studio_id = parent_studio_id")

                // Old profile must be deleted since the tag is gone
                _ = try oldProfile.delete(db)

                // A rename is a removal as far as every other library is
                // concerned. Without this, accepting a canonical name from a
                // lookup leaves the OLD name alive elsewhere, and the next sync
                // copies it back — the renamed actor reappears under both names.
                try recordTombstone(EntityTombstone(entityId: normalizedOld,
                                                    replacedBy: normalizedNew), in: db)
                // The destination id is deliberately live now, so any stale
                // tombstone naming it must go or the sync would delete what was
                // just created.
                try clearTombstone(for: normalizedNew, in: db)
                profileMoved = true
            }
        }
        return TagRenameOutcome(videosChanged: videosChanged,
                                profileMoved: profileMoved,
                                vocabularyRespelled: vocabularyRespelled)
    }

    /// The value part of a `tag:` id, or nil for any other category.
    ///
    /// Only `tag:` ids have a vocabulary row — actors and studios are
    /// `EntityProfile`s and are handled separately below.
    static func tagValue(of fullTag: String) -> String? {
        let parts = fullTag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "tag" else { return nil }
        return String(parts[1])
    }
    
    public func deleteAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try deleteAsset(asset, in: db)
        }
    }

    func deleteAsset(_ asset: Asset, in db: Database) throws {
        _ = try asset.delete(db)
    }

    /// Standardizes a series name: every asset whose `videoName` is one of
    /// `oldNames` is updated to `newName`. Used to merge freeform variations
    /// (casing, stray whitespace) of the same series into one canonical name.
    public func renameSeries(from oldNames: Set<String>, to newName: String) throws {
        try dbQueue.write { db in
            let assets = try Asset.fetchAll(db)
            for var asset in assets {
                if let current = asset.videoName, oldNames.contains(current), current != newName {
                    asset.videoName = newName
                    try asset.update(db)
                }
            }
        }
    }

    public func saveAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO assets (id, relative_path, file_name, status, created_at, tags)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    asset.id.uuidString,
                    asset.relativePath,
                    asset.fileName,
                    asset.status.rawValue,
                    Date(),
                    "[]"
                ]
            )
        }
    }
}

