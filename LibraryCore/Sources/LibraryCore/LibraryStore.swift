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
            .filter { $0.type == "actor" }
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
        // ⭐ Filtered by the type COLUMN. A prefix test returns zero rows on a
        // re-keyed library, which would not fail — it would silently report
        // that the library has no alias splits at all.
        let profiles = try fetchAllEntityProfiles().filter { $0.type == "actor" }

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
        // 🚨 Keyed by the RESOLVED id, because `byProfile` is already keyed by
        // `video_performer.performer_id` above. Two namespaces in one dictionary
        // would split each performer into two entries after the re-key — and
        // this feeds the alias-split audit, which compares video counts to
        // decide which of two rows is the alias.
        let resolver = NodeResolver(profiles: profiles)
        for asset in try fetchAllAssets() {
            for name in Set(asset.actors) {
                guard let id = resolver.localId(for: "actor:\(name)") else { continue }
                byProfile[id, default: []].insert(asset.id.uuidString)
            }
        }
        let counts = byProfile.mapValues(\.count)

        return AliasSplitAudit.findings(.init(
            profiles: profiles.map { ($0.id, $0.name, $0.akas,
                                      $0.enrichmentState == .matched, $0.birthYear) },
            videoCounts: counts))
    }

    /// Profiles nothing refers to, grouped by node kind.
    ///
    /// ⚠️ Gathers the edge sets as well as the strings. A check reading tag
    /// strings alone will propose deleting the library's entire cast the moment
    /// the string-retirement migration runs.
    public func auditOrphans() throws -> [GraphNodeKind: [OrphanFinding]] {
        // ⚠️ The columns travel with the id. Mapping to `\.id` alone is what
        // blinded this audit at the re-key — see `ProfileRef`.
        let profiles = try fetchAllEntityProfiles().map {
            ProfileRef(id: $0.id, entityType: $0.entityType, displayName: $0.displayName)
        }
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
        // 🚨 The anti-join is on the NAME, not the id.
        //
        // It used to compare the tag string `studio:Silver River` against
        // `entity_profiles.id`, which worked only because the id WAS that
        // string. After the re-key an id is a uid, so no tag ever matched,
        // every studio in the library looked missing, and a fresh row was
        // minted for all of them — once per library per session. Three
        // launches against the drive produced three copies of 469 studios.
        //
        // ⚠️ The mistake was narrow and worth naming: the minting inside this
        // function was updated for the re-key and the QUERY that feeds it was
        // not. Both halves have to move together.
        let missing: [String] = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT j.value
                FROM assets, json_each(assets.tags) j
                WHERE j.value LIKE 'studio:_%'
                  AND substr(j.value, 8) NOT IN (
                        SELECT display_name FROM entity_profiles
                         WHERE entity_type = 'studio' AND display_name IS NOT NULL)
                ORDER BY j.value
                """)
        }
        guard !missing.isEmpty else { return [] }

        // ⚠️ `missing` holds `studio:Name` TAG strings off videos, which is the
        // right input — but the ROW is minted through the one decision, so a
        // re-keyed library gets a uid rather than the tag string as a key.
        let rekeyed = try isRekeyed()
        try dbQueue.write { db in
            for tag in missing {
                let name = String(tag.dropFirst("studio:".count))
                let profile = EntityProfile(id: rekeyed ? UUID().uuidString : tag,
                                            entityType: "studio", displayName: name)
                try saveEntityProfile(profile, in: db)
            }
        }
        return missing
    }

    /// Gives a studio a profile row and claims NOTHING about its identity.
    ///
    /// ⭐ The counterpart to `confirmStudio`, for the caller that needs the row
    /// to exist without being able to evidence a match. A network named by a
    /// source that supplied no id for it is exactly that case: the row has to
    /// exist before `setStudioParent` can point at it — an edge to a studio
    /// with no profile is a dangling parent, one of the defects Studio Health
    /// reports — but nothing has established WHICH studio it is.
    ///
    /// 🚨 The distinction this method exists to preserve: `confirmStudio` sets
    /// `enrichmentState = .matched`, and `StudioBatchPolicy.skipReason` skips
    /// anything already matched. So confirming a studio the source could not
    /// identify closes the door on the one tool that could later identify it,
    /// while leaving a row that satisfies every column-reading check and holds
    /// no identity at all. Two studios in the drive library reached that state.
    ///
    /// ⚠️ Never disturbs an existing row. A studio already carrying a match —
    /// or a bio, or a hierarchy — is left exactly as it was; this only fills
    /// the absence.
    ///
    /// Returns whether a row was created, so a caller can report it rather
    /// than guess.
    @discardableResult
    public func ensureStudioProfile(_ name: String) throws -> Bool {
        guard try fetchEntityProfile(named: name, type: "studio") == nil else { return false }
        try saveEntityProfile(try newEntityProfile(named: name, type: "studio"))
        return true
    }

    /// A node for a performer the library has only ever seen as a cast string.
    ///
    /// 🚨 The counterpart of `ensureStudioProfile`, and its absence was a real
    /// hole. Confirming a video match created the STUDIO's row but not the
    /// cast's, so `recordCredits` and `propagateIdentities` — both of which
    /// resolve a name to a node and skip when there is none — silently wrote
    /// nothing for every performer on a newly matched video. The scene record
    /// hands over each performer's name, their source id, how they were
    /// credited and their billing, and all four were discarded.
    ///
    /// ⚠️ Minting from a name is normally refused (`entityId(named:)` never
    /// does it), and that rule is right: a name appearing somewhere is not
    /// evidence a person exists. A CONFIRMED MATCH is different — the source
    /// has told us this performer is in this scene, which is exactly the
    /// evidence `confirmStudio` already acts on for the studio.
    @discardableResult
    public func ensureActorProfile(_ name: String) throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = try fetchEntityProfile(named: trimmed, type: "actor") { return existing.id }
        let profile = try newEntityProfile(named: trimmed, type: "actor")
        try saveEntityProfile(profile)
        return profile.id
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
        // ⭐ Resolved by NAME and minted through the single decision, so this
        // finds the existing studio after the re-key instead of creating a
        // second one under a legacy-shaped key.
        var profile = try fetchEntityProfile(named: name, type: "studio")
            ?? (try newEntityProfile(named: name, type: "studio"))
        let id = profile.id

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

    /// The profile for a node of this type with this display name.
    ///
    /// 🚨 The lookup that survives the re-key. Callers overwhelmingly hold a
    /// NAME — a cast name off a video, a studio the source reported — and have
    /// been reaching profiles by building `"actor:\(name)"` and treating it as
    /// a primary key. That is only a key while the id encodes the name; after
    /// v28 it matches nothing and every one of those lookups returns nil,
    /// silently.
    ///
    /// ⭐ Reads the `entity_type` / `display_name` columns, which is what the
    /// `entity_lookup` index is on, so this is a keyed read rather than a
    /// scan. On today's rows it returns exactly what `fetchEntityProfile(for:)`
    /// returns for the equivalent legacy id — the columns are backfilled from
    /// that id by v34.
    ///
    /// ⚠️ Returns the FIRST match. `(entity_type, display_name)` is not unique
    /// — the unique index was deliberately moved to the migration tool's
    /// pre-flight so a duplicate cannot make a library unopenable. A caller
    /// that must distinguish duplicates should read them itself rather than
    /// asking for one.
    public func fetchEntityProfile(named name: String, type: String) throws -> EntityProfile? {
        guard !name.isEmpty, !type.isEmpty else { return nil }
        return try dbQueue.read { db in
            try EntityProfile
                .filter(sql: "entity_type = ? AND display_name = ?", arguments: [type, name])
                .fetchOne(db)
        }
    }
    
    /// Whether this library's primary keys are already opaque uids.
    ///
    /// 🚨 The test is `uid IS NOT NULL AND id = uid`, which is precisely the
    /// state `IdentityRekey.rekeyCommit` leaves behind — it mints into `uid`
    /// and then assigns `id = uid` in one transaction.
    ///
    /// ⚠️ Deliberately NOT "does any id lack a colon". That would also be true
    /// of a single malformed legacy row, and would flip the whole library's
    /// minting behaviour on one piece of damage. It is also not "is `uid`
    /// populated", which is true in the window after minting and before the
    /// commit — during which the keys are still legacy.
    ///
    /// An empty library answers false, which is right: a fresh library is
    /// created in the legacy shape and re-keyed later like any other.
    public func isRekeyed() throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM entity_profiles WHERE uid IS NOT NULL AND id = uid
                )
                """) ?? false
        }
    }

    /// A NEW profile for a node with this name, keyed the way this library
    /// keys things.
    ///
    /// ⭐ The single minting decision for the whole app, made in one place.
    /// Every path that creates an entity — confirming a studio, importing a
    /// CSV row, promoting a string — must come through here, or a re-keyed
    /// library starts quietly acquiring legacy-shaped ids again and ends up
    /// permanently half-migrated.
    ///
    /// ⚠️ The library decides, not the caller and not a build flag. Minting a
    /// uid before the re-key would be worse than useless: ~140 call sites still
    /// reach profiles by `"actor:\(name)"`, so a new actor would be created
    /// and then be invisible to the app that created it. Following the
    /// library's existing shape keeps this a no-op until the re-key genuinely
    /// runs, which is the same discipline as the rest of phase 0.
    ///
    /// ⚠️ `entityType` and `displayName` are always passed EXPLICITLY, in both
    /// branches. After the re-key there is nothing to derive them from, and a
    /// uid-keyed row without them is a profile with no recoverable name.
    ///
    /// Does NOT save. Minting and persisting are separate acts, and several
    /// callers build a stand-in they never intend to write.
    public func newEntityProfile(named name: String, type: String) throws -> EntityProfile {
        EntityProfile(id: try isRekeyed() ? UUID().uuidString : "\(type):\(name)",
                      entityType: type,
                      displayName: name)
    }

    /// Display names by node id, for one entity type.
    ///
    /// ⭐ Two columns, not whole profiles. Callers that need to LABEL a set of
    /// ids — the lineage view, a studio family — were decoding every column of
    /// every row in the library to read one string off a handful of them. This
    /// reads `(id, display_name)` straight off the `entity_lookup` index
    /// instead.
    public func entityNamesById(ofType type: String) throws -> [String: String] {
        try dbQueue.read { db in
            var out: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, display_name FROM entity_profiles WHERE entity_type = ?
                """, arguments: [type])
            for row in rows {
                let id: String = row["id"]
                // A row with no name still answers — with its id, which is
                // unreadable but never blank. Dropping it would make a damaged
                // studio vanish from the page instead of being fixable.
                //
                // ⚠️ EMPTY counts as absent, not just NULL — the same rule
                // `NodeResolver` and `EntityProfileIndex` apply. A blank string
                // would render as nothing at all, which is the one outcome
                // worse than a uid.
                let name = row["display_name"] as String?
                out[id] = (name?.isEmpty == false) ? name! : id
            }
            return out
        }
    }

    /// The id to WRITE under for a node with this name.
    ///
    /// 🚨 The distinction this exists to make impossible to get wrong. A caller
    /// that only DISPLAYS may fall back to the name form — a photo filename or
    /// a label is harmless if the row does not exist. A caller that SAVES may
    /// not: falling back to `"actor:\(name)"` in a re-keyed library creates a
    /// row with a legacy key, and the library is then permanently half
    /// migrated, one profile at a time.
    ///
    /// ⚠️ That is not hypothetical. Four actors were created exactly this way
    /// on 2026-08-09, minutes after the drive library was re-keyed — the editor
    /// was handed a name-form fallback because the actor had no row yet, and
    /// saved under it.
    ///
    /// Returns the existing row's id, or the id a new row would take. Does not
    /// save; minting and persisting stay separate.
    public func entityIdForWriting(named name: String, type: String) throws -> String {
        if let existing = try entityId(named: name, type: type) { return existing }
        // 🚨 SAVED, not merely minted. `newEntityProfile` is a pure factory —
        // it builds the row and stores nothing — so returning `.id` off it
        // handed back a uid that named nothing.
        //
        // Everything downstream then keyed edges and columns to an identifier
        // with no row behind it: the actor rendered as its own uid (the `name`
        // fallback is `displayName ?? parsed-id ?? id`, and a uid parses as
        // neither), `fetchEntityProfile(named:type:)` could not find it, and
        // `Missing Identities` dropped it for having no kind. One discarded
        // value, three symptoms.
        //
        // ⚠️ The name says "for writing". A caller asking for an id to write
        // against is entitled to assume the thing it identifies exists.
        let profile = try newEntityProfile(named: name, type: type)
        try saveEntityProfile(profile)
        return profile.id
    }

    /// The LOCAL id for a node named this, or nil when the library has none.
    ///
    /// ⭐ For the callers that need an id to hand to an edge writer —
    /// `setStudioParent`, `linkPerformer`, `setStudio` — and hold only a name.
    /// Building `"studio:\(name)"` and passing it works today and points at
    /// nothing after the re-key.
    ///
    /// ⚠️ Never mints. A caller that wants a row to exist says so explicitly
    /// (`ensureStudioProfile`), because minting from a name is exactly what the
    /// graph refuses to do by accident.
    public func entityId(named name: String, type: String) throws -> String? {
        try fetchEntityProfile(named: name, type: type)?.id
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
        // ⭐ Grouped and named by the COLUMNS. Both the prefix test and the
        // slice stop working once an id is a uid, and this is what makes an
        // alias resolve to its owner at all.
        for profile in profiles where profile.type == "actor" {
            if profile.akas.contains(normalizedName) {
                return profile.name
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
        // ⚠️ Canonicalised on the way in, like tags. The country is the one
        // field where the app stored presentation alongside the value — see
        // `CountryName` — and doing it here means no writer has to know.
        var profile = profile
        profile.countryOfOrigin = CountryName.canonical(profile.countryOfOrigin)
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
        // 🚨 A RENAME STOPS MOVING THINGS AFTER THE RE-KEY.
        //
        // Today a rename changes the id, so the profile row moves to a new
        // key, every edge has to be re-pointed at it, the photo files have to
        // be renamed, and a tombstone has to record that the old id is gone.
        // All of that is bookkeeping for a key that happens to contain a name.
        //
        // ⭐ Once the id is an opaque uid the node does not move at all. A pure
        // rename becomes one column update — `display_name` — plus the tag
        // strings on the videos. Re-pointing edges would be pointless; moving
        // photos would be actively wrong, since the files are named after the
        // stable uid.
        //
        // ⚠️ A MERGE still moves everything in both eras. Two distinct nodes
        // becoming one genuinely does re-point edges and photos, and the loser
        // genuinely is deleted. What changes is only the pure-rename case.
        let rekeyed = try isRekeyed()
        let entities = try resolveRenameEndpoints(oldTag: oldTag,
                                                  normalizedOld: normalizedOld,
                                                  normalizedNew: normalizedNew,
                                                  rekeyed: rekeyed)

        // Photo filenames follow the ENTITY ID, so the move is planned from the
        // resolved ids — and skipped entirely when the id is not changing.
        let oldSafeId = ProfileImageNaming.safeId(for: entities.sourceId ?? normalizedOld)
        let newSafeId = ProfileImageNaming.safeId(for: entities.destinationId ?? normalizedNew)
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
        if oldSafeId != newSafeId, FileManager.default.fileExists(atPath: profilesDir.path) {
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
                                              normalizedNew: normalizedNew,
                                              entities: entities)
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

    /// Which rows a rename actually touches.
    ///
    /// ⭐ Resolved ONCE, before any file or database work, because the photo
    /// move and the edge move both need the same answer and must not disagree.
    struct RenameEndpoints {
        /// The entity being renamed, if the library holds one.
        let sourceId: String?
        /// The entity it is merging INTO, if one already exists under the new
        /// name. Nil for a pure rename.
        let mergeTargetId: String?
        /// Whether this library's keys are opaque uids.
        let rekeyed: Bool
        /// The `type:Name` form of the new name, which IS the new key before
        /// the re-key and is only a name after it.
        let newNameFormId: String

        /// Where the photos and edges end up.
        ///
        /// 🚨 The whole inversion lives in this one property. For a merge it is
        /// the target, in both eras. For a PURE RENAME it is the new name-form
        /// id before the re-key — the key genuinely moves — and the UNCHANGED
        /// source id after, which is what makes the photo move and the edge
        /// re-point correctly become no-ops.
        var destinationId: String? {
            if let mergeTargetId { return mergeTargetId }
            guard let sourceId else { return nil }
            return rekeyed ? sourceId : newNameFormId
        }
    }

    private func resolveRenameEndpoints(oldTag: String,
                                        normalizedOld: String, normalizedNew: String,
                                        rekeyed: Bool) throws -> RenameEndpoints {
        guard rekeyed else {
            // Before the re-key the id IS the name, so the ids are the strings.
            let source = try fetchEntityProfile(for: normalizedOld)?.id
            let target = try fetchEntityProfile(for: normalizedNew)?.id
            return RenameEndpoints(sourceId: source,
                                   mergeTargetId: target,
                                   rekeyed: false,
                                   newNameFormId: normalizedNew)
        }
        // After it, both ends are found by identity — the strings are names.
        //
        // 🚨 The source is looked up under the spelling the CALLER gave first,
        // and only then under the normalized one. `normalize` title-cases, so
        // "tag:scuba" becomes "tag:Scuba" and a lookup by that name misses the
        // row stored in lower case — which is precisely the row a case
        // collision repair exists to find. This file already learned that
        // lesson for the asset tags; the profile lookup has to follow it too.
        let new = NodeIdentity.parse(normalizedNew)
        var source: String?
        for candidate in [NodeIdentity.parse(oldTag), NodeIdentity.parse(normalizedOld)] {
            guard let candidate, source == nil else { continue }
            source = try fetchEntityProfile(named: candidate.displayName,
                                            type: candidate.type)?.id
        }
        let target = try new.flatMap {
            try fetchEntityProfile(named: $0.displayName, type: $0.type)?.id
        }
        return RenameEndpoints(sourceId: source,
                               mergeTargetId: target == source ? nil : target,
                               rekeyed: true,
                               newNameFormId: normalizedNew)
    }

    @discardableResult
    private func renameTagInDatabase(oldTag: String, normalizedOld: String,
                                     normalizedNew: String,
                                     entities: RenameEndpoints) throws -> TagRenameOutcome {
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
                    // A rename can map two spellings onto one, so the row can
                    // come out holding the same tag twice.
                    asset.tags = asset.tags.deduplicatedPreservingOrder()
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
            if let sourceId = entities.sourceId,
               let oldProfile = try EntityProfile.fetchOne(db, key: sourceId) {

                // ⭐ A PURE RENAME AFTER THE RE-KEY MOVES NOTHING.
                //
                // The node keeps its uid, so there is no new key to write, no
                // edge to re-point, no photo to move and nothing to tombstone.
                // Only the name changes. Doing the old bookkeeping here would
                // re-point every edge at the id it already has and rename
                // photo files out from under themselves.
                if entities.rekeyed, entities.mergeTargetId == nil {
                    // ⚠️ Reports what actually happened. An unparseable or
                    // empty new name leaves the profile alone — and must not
                    // then claim the profile moved, or the caller shows a
                    // success for a rename that only touched the tag strings.
                    if let newName = NodeIdentity.parse(normalizedNew)?.displayName,
                       !newName.isEmpty {
                        try oldProfile.renamedInPlace(to: newName).save(db)
                        profileMoved = true
                    }
                    // Nothing follows this block inside the transaction — the
                    // tag strings and the vocabulary were handled above, and
                    // their counts are already recorded.
                    return
                }

                if var dest = try entities.mergeTargetId.flatMap({
                    try EntityProfile.fetchOne(db, key: $0)
                }) {
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
                // ⭐ ONE canonical list, shared with the re-key. This was a
                // literal here, and `entity_match` was once missing from it —
                // so merging two profiles discarded the identity one of them
                // had just been confirmed with. A list that has to be kept in
                // step by hand will eventually not be.
                for (table, column) in GraphTable.entityReferences {
                    // ⚠️ Resolved ids, never the name strings. After the
                    // re-key the endpoints are uids and a name-form string
                    // matches no edge at all — the UPDATE would touch nothing
                    // and the DELETE that follows would then destroy the
                    // source's edges outright, via ON DELETE CASCADE.
                    try db.execute(sql:
                        "UPDATE OR IGNORE \(table) SET \(column) = ? WHERE \(column) = ?",
                        arguments: [entities.destinationId ?? normalizedNew, sourceId])
                    try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ?",
                                   arguments: [sourceId])
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
                // ⚠️ NAME-keyed, per D4 — a tombstone names something that no
                // longer exists, so it can never hold a uid.
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

