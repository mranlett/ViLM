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
    public static func evictCachedConnections(keepingLibraryAt activeURL: URL?) {
        let keepPath = activeURL?
            .appendingPathComponent(".catalog")
            .appendingPathComponent("catalog.sqlite").path
        cacheLock.lock()
        defer { cacheLock.unlock() }
        queueCache = queueCache.filter { $0.key == keepPath }
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
        
        // Your existing v1
        migrator.registerMigration("v1") { db in
            try db.create(table: "assets") { t in
                t.column("id", .text).primaryKey()
                t.column("relative_path", .text).notNull().unique()
                t.column("file_name", .text).notNull()
                t.column("status", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }
        
        // --- NEW: Migration v2 adds the tags column ---
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
        
        // --- NEW: Migration v5 adds video name and episode tracking ---
        migrator.registerMigration("v5") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "video_name", .text)
                t.add(column: "episode", .text)
            }
        }
        
        // --- NEW: Migration v6 adds actor metadata ---
        migrator.registerMigration("v6") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "gender", .text)
                t.add(column: "hair_color", .text)
                t.add(column: "birth_year", .integer)
                t.add(column: "country_of_origin", .text)
            }
        }
        
        // --- NEW: Migration v7 adds actor tags ---
        migrator.registerMigration("v7") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "tags", .text).notNull().defaults(to: "[]")
            }
        }
        
        // --- NEW: Migration v8 adds gallery URLs ---
        migrator.registerMigration("v8") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "gallery_urls", .text).notNull().defaults(to: "[]")
            }
        }
        
        // --- NEW: Migration v9 adds created_at ---
        migrator.registerMigration("v9") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "created_at", .datetime)
            }
        }
        // --- NEW: Migration v10 adds smart collections ---
        migrator.registerMigration("v10") { db in
            try db.create(table: "smart_collections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("filterData", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        
        // --- NEW: Migration v11 adds akas to entity profiles ---
        migrator.registerMigration("v11") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "akas", .text).notNull().defaults(to: "[]")
            }
        }

        // --- NEW: Migration v12 adds structured season/episode numbers.
        // The existing `episode` text column is repurposed as the episode title.
        migrator.registerMigration("v12") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "season_number", .integer)
                t.add(column: "episode_number", .integer)
            }
        }

        // --- NEW: Migration v13 adds play count / last played tracking ---
        migrator.registerMigration("v13") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "play_count", .integer).notNull().defaults(to: 0)
                t.add(column: "last_played_at", .datetime)
            }
        }

        // --- NEW: Migration v14 adds scene markers (named, jumpable
        // timestamps within a video). ON DELETE CASCADE means a marker is
        // automatically removed the moment its video is deleted, regardless
        // of which of the app's several delete paths did it.
        migrator.registerMigration("v14") { db in
            try db.create(table: "scene_markers") { t in
                t.column("id", .text).primaryKey()
                t.column("asset_id", .text).notNull().indexed().references("assets", onDelete: .cascade)
                t.column("timestamp_seconds", .double).notNull()
                t.column("label", .text)
                t.column("created_at", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }
    
    // MARK: - Smart Collections
    
    public func fetchAllSmartCollections() throws -> [SmartCollection] {
        try dbQueue.read { db in
            try SmartCollection.order(Column("createdAt").asc).fetchAll(db)
        }
    }
    
    public func saveSmartCollection(_ collection: SmartCollection) throws {
        try dbQueue.write { db in
            try collection.save(db)
        }
    }
    
    public func deleteSmartCollection(id: String) throws {
        try dbQueue.write { db in
            _ = try SmartCollection.deleteOne(db, key: id)
        }
    }

    // MARK: - Scene Markers

    public func fetchSceneMarkers(for assetId: Asset.ID) throws -> [SceneMarker] {
        try dbQueue.read { db in
            try SceneMarker
                .filter(Column("asset_id") == assetId.uuidString)
                .order(Column("timestamp_seconds").asc)
                .fetchAll(db)
        }
    }

    public func saveSceneMarker(_ marker: SceneMarker) throws {
        try dbQueue.write { db in
            try marker.save(db)
        }
    }

    public func deleteSceneMarker(id: SceneMarker.ID) throws {
        try dbQueue.write { db in
            _ = try SceneMarker.deleteOne(db, key: id.uuidString)
        }
    }
    
    public func updateAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try asset.update(db)
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
            try EntityProfile.fetchAll(db)
        }
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
            try profile.save(db)
        }
    }
    
    public func renameTagGlobally(oldTag: String, newTag: String) throws {
        let normalizedOld = TagNormalizer.normalize(fullTag: oldTag)
        let normalizedNew = TagNormalizer.normalize(fullTag: newTag)
        if normalizedOld == normalizedNew { return }
        
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
        
        // Handle renaming image files on disk
        let oldSafeId = normalizedOld.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let newSafeId = normalizedNew.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        
        if FileManager.default.fileExists(atPath: profilesDir.path) {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil)
                for file in files {
                    let fileName = file.lastPathComponent
                    if fileName == "\(oldSafeId).jpg" {
                        let newFile = profilesDir.appendingPathComponent("\(newSafeId).jpg")
                        try? FileManager.default.moveItem(at: file, to: newFile)
                    } else if fileName.hasPrefix("\(oldSafeId)_") && fileName.hasSuffix(".jpg") {
                        let suffix = String(fileName.dropFirst(oldSafeId.count))
                        let newFileName = newSafeId + suffix
                        let newFile = profilesDir.appendingPathComponent(newFileName)
                        try? FileManager.default.moveItem(at: file, to: newFile)
                    }
                }
            } catch {
                print("Failed to rename profile images: \(error)")
            }
        }
    }
    
    public func deleteAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            _ = try asset.delete(db)
        }
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
