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

    public func saveAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO assets (id, relative_path, file_name, status, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    asset.id.uuidString,
                    asset.relativePath,
                    asset.fileName,
                    asset.status.rawValue,
                    Date()
                ]
            )
        }
    }
}
