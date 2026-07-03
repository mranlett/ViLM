import Foundation
import GRDB

public class LibraryStore {
    private let dbQueue: DatabaseQueue

    public init(at url: URL) throws {
        let catalogURL = url.appendingPathComponent(".catalog")
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        let dbPath = catalogURL.appendingPathComponent("catalog.sqlite").path

        let config: Configuration = {
            var c = Configuration()
            c.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            return c
        }()

        self.dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try migrate()
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
        
        try migrator.migrate(dbQueue)
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
                if let index = asset.tags.firstIndex(of: normalizedOld) {
                    asset.tags[index] = normalizedNew
                    
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
                let destExists = try EntityProfile.fetchOne(db, key: normalizedNew) != nil
                
                if !destExists {
                    // Safe to rename the profile
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
                        galleryUrls: oldProfile.galleryUrls
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
            _ = try asset.delete(db)
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
