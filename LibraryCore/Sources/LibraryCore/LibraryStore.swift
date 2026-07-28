// LibraryStore.swift
// The SQLite (GRDB) persistence layer: one cached connection per library,
// schema migrations v1-v14, and all CRUD for assets, entity profiles, smart
// collections, scene markers, plus global tag/series rename operations.

import Foundation
import GRDB

public class LibraryStore {
    private let dbQueue: DatabaseQueue
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
        let keepPath = activeURL?
            .appendingPathComponent(".catalog")
            .appendingPathComponent("catalog.sqlite").path
        cacheLock.lock()
        defer { cacheLock.unlock() }
        queueCache = queueCache.filter { $0.key == keepPath }
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


    private func migrate() throws {
        var migrator = DatabaseMigrator()
        
        // v1: initial schema — the assets table.
        migrator.registerMigration("v1") { db in
            try db.create(table: "assets") { t in
                t.column("id", .text).primaryKey()
                t.column("relative_path", .text).notNull().unique()
                t.column("file_name", .text).notNull()
                t.column("status", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }
        
        // v2: adds the tags column
        migrator.registerMigration("v2") { db in
            // We add the column as a text field that defaults to an empty JSON array
            try db.alter(table: "assets") { t in
                t.add(column: "tags", .text).notNull().defaults(to: "[]")
            }
        }
        
        migrator.registerMigration("v3") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "external_link", .text)
            }
            try db.create(table: "entity_profiles") { t in
                t.column("id", .text).primaryKey()
                t.column("bio", .text)
                t.column("photo_url", .text)
                t.column("home_page", .text)
            }
        }
        
        migrator.registerMigration("v4") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "notes", .text)
                t.add(column: "rating", .integer)
            }
        }
        
        // v5: adds video name and episode tracking
        migrator.registerMigration("v5") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "video_name", .text)
                t.add(column: "episode", .text)
            }
        }
        
        // v6: adds actor metadata
        migrator.registerMigration("v6") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "gender", .text)
                t.add(column: "hair_color", .text)
                t.add(column: "birth_year", .integer)
                t.add(column: "country_of_origin", .text)
            }
        }
        
        // v7: adds actor tags
        migrator.registerMigration("v7") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "tags", .text).notNull().defaults(to: "[]")
            }
        }
        
        // v8: adds gallery URLs
        migrator.registerMigration("v8") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "gallery_urls", .text).notNull().defaults(to: "[]")
            }
        }
        
        // v9: adds created_at
        migrator.registerMigration("v9") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "created_at", .datetime)
            }
        }
        // v10: adds smart collections
        migrator.registerMigration("v10") { db in
            try db.create(table: "smart_collections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("filterData", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        
        // v11: adds akas to entity profiles
        migrator.registerMigration("v11") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "akas", .text).notNull().defaults(to: "[]")
            }
        }

        // v12: adds structured season/episode numbers.
        // The existing `episode` text column is repurposed as the episode title.
        migrator.registerMigration("v12") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "season_number", .integer)
                t.add(column: "episode_number", .integer)
            }
        }

        // v13: adds play count / last played tracking
        migrator.registerMigration("v13") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "play_count", .integer).notNull().defaults(to: 0)
                t.add(column: "last_played_at", .datetime)
            }
        }

        // v14: adds scene markers (named, jumpable timestamps within a
        // video). ON DELETE CASCADE means a marker is automatically removed
        // the moment its video is deleted, regardless of which of the app's
        // several delete paths did it.
        migrator.registerMigration("v14") { db in
            try db.create(table: "scene_markers") { t in
                t.column("id", .text).primaryKey()
                t.column("asset_id", .text).notNull().indexed().references("assets", onDelete: .cascade)
                t.column("timestamp_seconds", .double).notNull()
                t.column("label", .text)
                t.column("created_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v15") { db in
            // v15: actor favorite rating (1–5, nullable). Additive only — the
            // backup feature requires migrations never drop/rewrite columns so
            // old .vilmbackup archives always restore.
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "rating", .integer)
            }
        }

        try migrator.migrate(dbQueue)
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

    // MARK: - Scene Markers

    public func fetchSceneMarkers(for assetId: Asset.ID) throws -> [SceneMarker] {
        try dbQueue.read { db in
            try fetchSceneMarkers(for: assetId, in: db)
        }
    }

    func fetchSceneMarkers(for assetId: Asset.ID, in db: Database) throws -> [SceneMarker] {
        try SceneMarker
            .filter(Column("asset_id") == assetId.uuidString)
            .order(Column("timestamp_seconds").asc)
            .fetchAll(db)
    }

    public func saveSceneMarker(_ marker: SceneMarker) throws {
        try dbQueue.write { db in
            try saveSceneMarker(marker, in: db)
        }
    }

    func saveSceneMarker(_ marker: SceneMarker, in db: Database) throws {
        try marker.save(db)
    }

    public func deleteSceneMarker(id: SceneMarker.ID) throws {
        try dbQueue.write { db in
            try deleteSceneMarker(id: id, in: db)
        }
    }

    func deleteSceneMarker(id: SceneMarker.ID, in db: Database) throws {
        _ = try SceneMarker.deleteOne(db, key: id.uuidString)
    }
    
    public func updateAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try updateAsset(asset, in: db)
        }
    }

    func updateAsset(_ asset: Asset, in db: Database) throws {
        try asset.update(db)
    }

    /// Inserts a fully-populated asset row (every column), unlike the
    /// scanner's `saveAsset` which is an INSERT-OR-IGNORE that only writes the
    /// handful of columns a freshly-discovered file has. Used by the video
    /// transfer tool to persist a moved asset's complete metadata in one shot.
    public func insertAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try insertAsset(asset, in: db)
        }
    }

    func insertAsset(_ asset: Asset, in db: Database) throws {
        try asset.insert(db)
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

    public func renameTagGlobally(oldTag: String, newTag: String) throws {
        let normalizedOld = TagNormalizer.normalize(fullTag: oldTag)
        let normalizedNew = TagNormalizer.normalize(fullTag: newTag)
        if normalizedOld == normalizedNew { return }

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

        do {
            try renameTagInDatabase(normalizedOld: normalizedOld, normalizedNew: normalizedNew)
        } catch {
            rollbackMoves()
            throw error
        }

        // Committed: remove the now-unreferenced colliding sources rather
        // than leaving invisible orphans on disk.
        for url in collidingSources {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func renameTagInDatabase(normalizedOld: String, normalizedNew: String) throws {
        try dbQueue.write { db in
            let assets = try Asset.fetchAll(db)
            for var asset in assets {
                var modified = false
                for i in 0..<asset.tags.count {
                    if asset.tags[i] == normalizedOld {
                        asset.tags[i] = normalizedNew
                        modified = true
                    }
                }
                
                if modified {
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
                    try dest.save(db)
                } else {
                    // Safe to rename the profile. Carry every field —
                    // omitting akas here used to silently drop all of an
                    // actor's aliases on rename.
                    let newProfile = EntityProfile(
                        id: normalizedNew,
                        bio: oldProfile.bio,
                        photoUrl: oldProfile.photoUrl,
                        homePage: oldProfile.homePage,
                        gender: oldProfile.gender,
                        hairColor: oldProfile.hairColor,
                        birthYear: oldProfile.birthYear,
                        countryOfOrigin: oldProfile.countryOfOrigin,
                        rating: oldProfile.rating,
                        tags: oldProfile.tags,
                        galleryUrls: oldProfile.galleryUrls,
                        akas: oldProfile.akas,
                        createdAt: oldProfile.createdAt
                    )
                    try newProfile.save(db)
                }

                // Old profile must be deleted since the tag is gone
                _ = try oldProfile.delete(db)
            }
        }
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
