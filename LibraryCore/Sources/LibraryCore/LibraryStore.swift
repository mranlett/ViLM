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

        // v16: playlists — hand-picked ordered video lists. Additive (new
        // tables only) so old archives still restore. `assetId` deliberately
        // has NO foreign key: a playlist may reference an ATTACHED library's
        // video (multi-library session), whose row lives in another database.
        // The composite primary key is the no-duplicates rule.
        migrator.registerMigration("v16") { db in
            try db.create(table: "playlists") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "playlist_items") { t in
                t.column("playlistId", .text).notNull()
                    .references("playlists", onDelete: .cascade)
                t.column("assetId", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["playlistId", "assetId"])
            }
        }

        // v17: career span + precise birth date. Additive only, five nullable
        // columns — old .vilmbackup archives still restore, and every existing
        // row reads as "no career recorded" rather than as wrong data.
        //
        // Generic on purpose: a career span carries no domain assumption and is
        // populated by CSV import, by hand, or not at all. Nothing here depends
        // on a metadata provider existing.
        migrator.registerMigration("v17") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "birth_date", .text)
                t.add(column: "career_span_raw", .text)
                t.add(column: "career_start_year", .integer)
                t.add(column: "career_end_year", .integer)
                t.add(column: "age_at_career_start", .integer)
            }
        }

        // v18: enrichment state. Additive only, three nullable columns.
        //
        // Generic by construction — records that a lookup ran and what it
        // concluded, never which provider ran it. A second provider reuses
        // these columns with no migration.
        migrator.registerMigration("v18") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "enrichment_state", .text)
                t.add(column: "enrichment_source", .text)
                t.add(column: "enrichment_checked_at", .datetime)
            }
        }

        // v19: labelled external links. Additive, one nullable column holding a
        // JSON array — same shape as tags/akas/gallery_urls.
        //
        // Generalises `home_page`, which is kept: a single home page is still a
        // meaningful concept, and dropping a column would break the additive-only
        // rule the backup feature depends on.
        migrator.registerMigration("v19") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "links", .text).notNull().defaults(to: "[]")
            }
        }

        // v23 — the source's own id for a matched person.
        //
        // A validated match was being thrown away: every later lookup
        // re-searched by name and re-guessed which of several same-named
        // people was meant. Keeping the id turns a guess into a lookup.
        migrator.registerMigration("v23") { db in
            try db.alter(table: "entity_profiles") { t in
                t.add(column: "enrichment_source_id", .text)
            }
        }

        // v22 — lookup state on a video.
        //
        // The actor side has had this since v18. A video an external source
        // cannot identify — a re-cut copy, something never catalogued — is
        // otherwise indistinguishable from one nobody has tried yet, so it
        // sits in the queue forever.
        migrator.registerMigration("v22") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "enrichment_state", .text)
                t.add(column: "enrichment_source", .text)
                t.add(column: "enrichment_checked_at", .datetime)
            }
        }

        // v21 — publication date.
        //
        // The only field a matched source record carries that the library had
        // nowhere to put. Series, volume, episode number and episode title all
        // map onto columns that already exist; performers and studio ride on
        // the tag conventions.
        migrator.registerMigration("v21") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "release_date", .text)
            }
        }

        // v24 — the source's own id for a matched VIDEO, and a link to it.
        //
        // v23 did this for people. The video half was never done, so a
        // validated scene match was thrown away and every later run
        // re-searched by name and re-guessed which record was meant.
        //
        // The url is a separate column rather than derived from the id: core
        // cannot build a link without knowing the source's address, and core
        // never names a source. The provider supplies both or neither.
        //
        // Additive and nullable, so existing rows migrate without
        // interpretation. Nothing backfills them — an id is written the next
        // time a match is confirmed, because rediscovering one by name would
        // be exactly the re-guessing this column exists to eliminate.
        migrator.registerMigration("v24") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "enrichment_source_id", .text)
                t.add(column: "enrichment_url", .text)
            }
        }

        // v26 — the tag vocabulary: what each tag DESCRIBES.
        //
        // A table of its own rather than columns on `entity_profiles`. That
        // record is at the Swift type-checker's practical limit at 23 stored
        // properties — adding one field has already broken three construction
        // sites with an error naming neither the field nor reliably the file —
        // and a tag needs exactly three things: identity, display name, kind.
        // Storing it in an actor-shaped record would give every tag a bio, a
        // birth date and a career span, which is coupling wearing reuse's coat.
        //
        // `kind` is NULL for every promoted tag, which reads as "unclassified":
        // deliberately unusable, so nothing is ever guessed.
        //
        // `identity_key` is the case- and diacritic-folded name, computed in
        // Swift — never with SQLite's `lower()`, which is ASCII-only and would
        // still admit duplicates for an accented name. It exists because one
        // tag was stored under two casings and became two things; folding at
        // the storage layer makes that impossible rather than merely
        // detectable.
        //
        // ⚠️ The KEY is the folded name alone — kind is an attribute, not part
        // of identity. An earlier draft keyed on (identity_key, kind) so that a
        // tag could later split into two nodes sharing a name. That is wrong
        // for a reason a test caught immediately: identity would then depend on
        // a MUTABLE attribute, so classifying a tag would change its key and
        // insert a second row instead of updating the first. A tag ended up
        // both unclassified and classified at once.
        //
        // Splitting one name into two kinds therefore needs two genuinely
        // distinct identities, which is what the opaque-node-id work provides.
        // It is not needed by any tag measured in the library today.
        migrator.registerMigration("v26") { db in
            try db.create(table: "tags") { t in
                t.primaryKey("identity_key", .text)
                t.column("display_name", .text).notNull()
                t.column("kind", .text)
            }
        }

        // v27 — the edges.
        //
        // Until now the graph was stored as prefixed display-name STRINGS in a
        // JSON array on each asset, so "which videos feature this performer"
        // meant loading every asset and string-matching. The join key was a
        // name, which is why renaming needed a global mechanism, why aliases
        // are a special case everywhere, and why one tag under two casings
        // became two things.
        //
        // ⚠️ One table per edge kind rather than one polymorphic table: each
        // carries a DIFFERENT cardinality, and a shared table can enforce none
        // of them. `video_studio`'s primary key on `video_id` alone is what
        // makes "a scene has one releasing studio" structural rather than a
        // rule someone has to remember.
        //
        // ⚠️ Edges reference the ids that exist TODAY — `assets.id`, and
        // `entity_profiles.id` in its `prefix:Name` form. Opaque node ids are a
        // separate, later migration, and it re-points every table here. Waiting
        // for it would mean no edges at all until the largest migration in the
        // project lands.
        //
        // ⚠️ Nothing is written here. Creating the tables is additive and
        // reversible; filling them is a separate, gated step, and the legacy
        // strings stay authoritative until it has been verified.
        migrator.registerMigration("v27") { db in
            try db.create(table: "video_performer") { t in
                t.column("video_id", .text).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("performer_id", .text).notNull()
                    .references("entity_profiles", onDelete: .cascade)
                t.primaryKey(["video_id", "performer_id"])
            }

            // PK on video_id alone: a second releasing studio cannot be
            // inserted, so the studio-conflict audit has nothing left to find.
            try db.create(table: "video_studio") { t in
                t.column("video_id", .text).notNull().primaryKey()
                    .references("assets", onDelete: .cascade)
                t.column("studio_id", .text).notNull()
                    .references("entity_profiles", onDelete: .cascade)
            }

            try db.create(table: "video_tag") { t in
                t.column("video_id", .text).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("tag_id", .text).notNull()
                    .references("tags", onDelete: .cascade)
                t.primaryKey(["video_id", "tag_id"])
            }

            try db.create(table: "performer_tag") { t in
                t.column("performer_id", .text).notNull()
                    .references("entity_profiles", onDelete: .cascade)
                t.column("tag_id", .text).notNull()
                    .references("tags", onDelete: .cascade)
                t.primaryKey(["performer_id", "tag_id"])
            }

            // A studio with no row here IS a root studio. Absence means root;
            // there is deliberately no NULL-parent row to interpret.
            //
            // Cascading on the parent removes the HIERARCHY row, not the child
            // profile — so deleting a network promotes its imprints to roots
            // rather than deleting them with it.
            try db.create(table: "studio_parent") { t in
                t.column("studio_id", .text).notNull().primaryKey()
                    .references("entity_profiles", onDelete: .cascade)
                t.column("parent_studio_id", .text).notNull()
                    .references("entity_profiles", onDelete: .cascade)
            }

            // NOT an edge. Where a tag was found before anyone said what it
            // describes, so the link survives until it can become one.
            // Invisible to every graph query.
            try db.create(table: "pending_tag_association") { t in
                t.column("video_id", .text).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("tag_id", .text).notNull()
                    .references("tags", onDelete: .cascade)
                t.primaryKey(["video_id", "tag_id"])
            }
        }

        // v20 — deletions recorded as facts.
        //
        // Sync unions what each library holds, so an absence is indistinguishable
        // from a deliberate removal and deleted actors come back on the next
        // pass. Renames are the usual source: accepting a canonical name is a
        // delete plus a create, and only the create was ever visible.
        migrator.registerMigration("v20") { db in
            try db.create(table: "deleted_entities") { t in
                t.column("entity_id", .text).primaryKey()
                t.column("deleted_at", .datetime).notNull()
                t.column("replaced_by", .text)
            }
        }

        // v29 — edge attributes, phase 1. Facts ABOUT a relationship.
        //
        // Every edge table was `(from, to)` and nothing else, so an edge could
        // state that a relationship exists and nothing about it. Two things
        // were lost to that:
        //
        //   PROVENANCE   D7 says every value carries its source. Edges did not,
        //                so an edge asserted by a confirmed match and one
        //                inferred from a filename were indistinguishable
        //                afterwards — which is why `Match Again` cannot tell a
        //                confirmed edge from a guessed one.
        //
        //   CREDITED-AS  the name a performer appeared under in a specific
        //                scene. The source supplies it on every match; it is a
        //                property of the APPEARANCE, not of the person or the
        //                video, so there was nowhere to put it and it was
        //                discarded every time.
        //
        // ⚠️ Additive only. No primary key moves and no row is rewritten, so
        // every existing edge reads as "provenance unknown" — which is true.
        //
        // ⚠️ Validity dates are deliberately NOT here. Dating an edge changes
        // what an edge IS and takes a primary key with it (`video_studio` and
        // `studio_parent` are keyed on one column each, encoding "exactly one,
        // forever"). That is phase 2, and its own spec.
        //
        // 🚨 Registration order, NOT name order. The migrator runs these in the
        // order they are registered in this file, which is already out of
        // numeric sequence above — v23, v22, v21, v24, v26, v27, v20. This is
        // last because it is written last, not because it is numbered highest.
        migrator.registerMigration("v29") { db in
            // Provenance is universal: every edge came from somewhere.
            for table in ["video_performer", "video_studio", "video_tag",
                          "performer_tag", "studio_parent", "pending_tag_association"] {
                try db.alter(table: table) { t in
                    t.add(column: "source", .text)
                    t.add(column: "recorded_at", .datetime)
                }
            }

            // Facts about an APPEARANCE, so they belong on that edge alone —
            // a credited name means nothing on a studio hierarchy.
            try db.alter(table: "video_performer") { t in
                t.add(column: "credited_as", .text)
                t.add(column: "billing", .integer)
            }
        }

        // v30 — temporal studio hierarchy. Edge attributes, phase 2.
        //
        // An imprint owned by one network until 2015 and another after it is
        // TWO facts, and the old key — `studio_id` alone — could hold only one.
        // That key encoded "exactly one parent, forever", which is not true of
        // companies.
        //
        // ⚠️ Scoped to `studio_parent` alone. `performer_tag` was considered
        // and deliberately excluded: no source supplies "blonde from 2016", so
        // a validity column there could only ever hold a guess — and a guess in
        // a date column stops looking like a guess the moment it is read back.
        // v29's `recorded_at` already says everything honestly knowable about
        // when that edge was learned.
        //
        // 🚨 SQLite cannot alter a primary key in place, so this is a REBUILD.
        // Every existing row copies across as "current, start unknown", which
        // is exactly what it is.
        migrator.registerMigration("v30") { db in
            try db.create(table: "studio_parent_new") { t in
                t.column("studio_id", .text).notNull()
                    .references("entity_profiles", onDelete: .cascade)
                t.column("parent_studio_id", .text).notNull()
                    .references("entity_profiles", onDelete: .cascade)
                // NULL = "as far back as we know", NOT "never". Every migrated
                // row carries NULL, so reading it as "no match" would make the
                // whole existing hierarchy vanish from as-of queries.
                t.column("valid_from", .text)
                // NULL = still current.
                t.column("valid_to", .text)
                t.column("source", .text)
                t.column("recorded_at", .datetime)
            }

            // ⚠️ Copy BEFORE the index exists. Today's data satisfies it by
            // construction — one row per studio — but creating the index first
            // would turn a duplicate into a cryptic constraint error instead of
            // a diagnosable insert.
            try db.execute(sql: """
                INSERT INTO studio_parent_new
                    (studio_id, parent_studio_id, valid_from, valid_to, source, recorded_at)
                SELECT studio_id, parent_studio_id, NULL, NULL, source, recorded_at
                  FROM studio_parent
                """)

            try db.drop(table: "studio_parent")
            try db.rename(table: "studio_parent_new", to: "studio_parent")

            // ⭐ The rule "at most one OPEN parent per studio" as a database
            // constraint rather than an application convention — the only form
            // that survives a second writer. Historical rows are unconstrained.
            try db.execute(sql: """
                CREATE UNIQUE INDEX studio_parent_current
                    ON studio_parent(studio_id) WHERE valid_to IS NULL
                """)
        }

        try migrator.migrate(dbQueue)
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

    // MARK: - Playlists

    public func fetchAllPlaylists() throws -> [Playlist] {
        try dbQueue.read { db in
            try fetchAllPlaylists(in: db)
        }
    }

    func fetchAllPlaylists(in db: Database) throws -> [Playlist] {
        try Playlist.order(Column("createdAt").asc).fetchAll(db)
    }

    /// Items in their manual order.
    public func fetchPlaylistItems(playlistId: String) throws -> [PlaylistItem] {
        try dbQueue.read { db in
            try fetchPlaylistItems(playlistId: playlistId, in: db)
        }
    }

    func fetchPlaylistItems(playlistId: String, in db: Database) throws -> [PlaylistItem] {
        try PlaylistItem
            .filter(Column("playlistId") == playlistId)
            .order(Column("position").asc)
            .fetchAll(db)
    }

    @discardableResult
    public func createPlaylist(named name: String) throws -> Playlist {
        let playlist = Playlist(name: name)
        try dbQueue.write { db in
            try playlist.insert(db)
        }
        return playlist
    }

    public func renamePlaylist(id: String, to name: String) throws {
        try dbQueue.write { db in
            if var playlist = try Playlist.fetchOne(db, key: id) {
                playlist.name = name
                try playlist.update(db)
            }
        }
    }

    /// Removes the playlist and (via cascade) its memberships. The videos
    /// themselves are untouched — a playlist is only a list.
    public func deletePlaylist(id: String) throws {
        try dbQueue.write { db in
            _ = try Playlist.deleteOne(db, key: id)
        }
    }

    /// Appends `assetIds` that aren't already members, in the given order, at
    /// the END of the playlist (one transaction). Duplicates are silently
    /// skipped so "Select All → Add" is safely repeatable. Returns how many
    /// were actually added.
    @discardableResult
    public func addToPlaylist(id: String, assetIds: [Asset.ID]) throws -> Int {
        try performInTransaction { db in
            let existing = Set(try fetchPlaylistItems(playlistId: id, in: db).map(\.assetId))
            let maxPosition = try Int.fetchOne(
                db, sql: "SELECT MAX(position) FROM playlist_items WHERE playlistId = ?",
                arguments: [id]) ?? -1
            var next = maxPosition + 1
            var added = 0
            for assetId in assetIds where !existing.contains(assetId.uuidString) {
                try PlaylistItem(playlistId: id, assetId: assetId.uuidString, position: next).insert(db)
                next += 1
                added += 1
            }
            return added
        }
    }

    public func removeFromPlaylist(id: String, assetIds: [Asset.ID]) throws {
        let idStrings = assetIds.map(\.uuidString)
        try dbQueue.write { db in
            _ = try PlaylistItem
                .filter(Column("playlistId") == id)
                .filter(idStrings.contains(Column("assetId")))
                .deleteAll(db)
        }
    }

    /// Persists a complete manual re-ordering: positions are rewritten to the
    /// index of each entry in `orderedAssetIds` (one transaction). Members
    /// not mentioned keep their rows but sort after the mentioned ones.
    public func reorderPlaylist(id: String, orderedAssetIds: [Asset.ID]) throws {
        try performInTransaction { db in
            for (index, assetId) in orderedAssetIds.enumerated() {
                try db.execute(
                    sql: "UPDATE playlist_items SET position = ? WHERE playlistId = ? AND assetId = ?",
                    arguments: [index, id, assetId.uuidString])
            }
        }
    }

    /// "Remove Unavailable": drops entries whose videos aren't in
    /// `availableIds` (the current open-library union). Explicit user action
    /// only — dangling entries are otherwise kept, since detaching a library
    /// makes its videos unavailable without making them gone.
    public func prunePlaylistEntries(playlistId: String, keeping availableIds: Set<Asset.ID>) throws {
        let keep = Set(availableIds.map(\.uuidString))
        try dbQueue.write { db in
            let items = try fetchPlaylistItems(playlistId: playlistId, in: db)
            for item in items where !keep.contains(item.assetId) {
                try db.execute(
                    sql: "DELETE FROM playlist_items WHERE playlistId = ? AND assetId = ?",
                    arguments: [item.playlistId, item.assetId])
            }
        }
    }

    /// Removes a deleted video's memberships across all of THIS library's
    /// playlists (the delete path's cleanup; cross-library dangling entries
    /// are tolerated by display instead).
    func removePlaylistEntries(assetId: Asset.ID, in db: Database) throws {
        _ = try PlaylistItem
            .filter(Column("assetId") == assetId.uuidString)
            .deleteAll(db)
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

    // MARK: - Connecting: strings to edges

    /// What connecting performers would do, counted before anything is written.
    public struct ConnectPlan: Equatable, Sendable {
        /// Credits found in the legacy strings.
        public let associations: Int
        /// Distinct names among them that have no profile row, and so cannot be
        /// pointed at. Reported rather than created: inventing a person from a
        /// string is exactly what the parser is forbidden to do.
        public let missingProfiles: [String]
        /// Edges that already exist and would not be duplicated.
        public let alreadyConnected: Int
        /// 🚨 Credits that CAN be connected and are not yet — counted by
        /// intersecting the wanted pairs with the existing ones.
        ///
        /// This used to be `associations - alreadyConnected`, subtracting a
        /// GLOBAL edge count from a TOTAL association count. Two different
        /// sets: the numerator included credits whose performer has no profile
        /// and so can never become an edge, and the subtrahend counted edges
        /// that had nothing to do with them.
        ///
        /// On a real library that reported **484** when the run created
        /// **3** — reported from the device, 2026-08-07.
        public let connectable: Int
        /// Credits skipped because the name has no profile. `associations`
        /// minus this is what could ever be connected.
        public let skippedNoProfile: Int
    }

    /// Builds `video_performer` edges from the `actor:` strings.
    ///
    /// ⚠️ ADDITIVE AND NON-DESTRUCTIVE. The strings are read, never written and
    /// never removed — they stay authoritative until a separate, gated step
    /// retires them. Running this changes what the graph CAN answer, not what
    /// it says.
    ///
    /// Idempotent: an existing edge is left alone, so a re-run after adding
    /// videos connects only the new ones.
    ///
    /// ⚠️ A credit naming someone with no profile row is SKIPPED and reported.
    /// Creating the profile here would mint a person from a string that a
    /// filename parse may well have guessed — the one thing the parser itself
    /// is not allowed to do, and it must not happen by a side door.
    @discardableResult
    public func connectPerformerEdges(dryRun: Bool = false) throws -> ConnectPlan {
        let assets = try fetchAllAssets()
        let known = Set(try fetchAllEntityProfiles().map(\.id))

        var associations = 0
        var missing = Set<String>()
        var wanted: [(UUID, String)] = []

        for asset in assets {
            // Set: a video crediting the same performer twice is one credit.
            for name in Set(asset.actors) where !name.isEmpty {
                associations += 1
                let id = "actor:\(name)"
                if known.contains(id) { wanted.append((asset.id, id)) } else { missing.insert(name) }
            }
        }

        // The pairs, not the count — the count cannot say which of `wanted`
        // is already present, which is the only question worth asking.
        let existingPairs: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT video_id, performer_id FROM video_performer")
                .map { "\($0["video_id"] as String)|\($0["performer_id"] as String)" })
        }
        let existing = existingPairs.count
        let notYetConnected = wanted.filter {
            !existingPairs.contains("\($0.0.uuidString)|\($0.1)")
        }.count

        if !dryRun {
            try dbQueue.write { db in
                for (videoId, performerId) in wanted {
                    // ⚠️ `inferred`, not `filename` or `download`. This walks
                    // `asset.tags`, and those came from every route there is —
                    // claiming a specific origin would be inventing provenance
                    // rather than recording it.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO video_performer
                            (video_id, performer_id, source, recorded_at)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [videoId.uuidString, performerId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
            }
        }

        return ConnectPlan(associations: associations,
                           missingProfiles: missing.sorted(),
                           alreadyConnected: existing,
                           connectable: notYetConnected,
                           skippedNoProfile: associations - wanted.count)
    }

    /// Whether the edges reproduce what the strings say, for every video.
    ///
    /// ⚠️ The gate on retiring the strings. Counting edges alone would pass a
    /// migration that connected the right NUMBER of things to the wrong videos,
    /// so this compares per video and returns the ones that disagree.
    public func performerEdgeDisagreements() throws -> [UUID] {
        let assets = try fetchAllAssets()
        let known = Set(try fetchAllEntityProfiles().map(\.id))

        var disagreeing: [UUID] = []
        for asset in assets {
            // Only credits that COULD become edges are compared: a name with no
            // profile is a known, reported gap, not a disagreement.
            let expected = Set(asset.actors.map { "actor:\($0)" }).intersection(known)
            let actual = Set(try performerIds(forVideo: asset.id))
            if expected != actual { disagreeing.append(asset.id) }
        }
        return disagreeing
    }

    /// What connecting studios would do, and what stands in the way.
    public struct StudioConnectPlan: Equatable, Sendable {
        public let associations: Int
        public let missingProfiles: [String]
        public let alreadyConnected: Int
        /// ⚠️ Videos carrying MORE THAN ONE studio. These cannot be connected:
        /// `video_studio` permits one per video, so the schema now refuses what
        /// the strings were happy to hold. They are skipped and listed.
        public let conflicted: [UUID]
        /// Studio links that CAN be connected and are not yet.
        ///
        /// 🚨 Same correction as `ConnectPlan.connectable` — see there. The
        /// old subtraction happened to look plausible for studios because
        /// almost every studio has a profile, and was badly wrong for
        /// performers where 190 names do not.
        public let connectable: Int
        /// Videos whose studio has no profile row.
        public let skippedNoProfile: Int

        public var isBlocked: Bool { !conflicted.isEmpty }
    }

    /// Builds `video_studio` edges from the `studio:` strings.
    ///
    /// ⚠️ THE CONFLICT AUDIT BECOMES A GATE HERE. A scene has one releasing
    /// studio, and the primary key says so — so a video the strings gave two
    /// cannot be represented at all. Those videos are skipped and reported
    /// rather than one studio being picked arbitrarily: choosing for the
    /// operator would silently discard a fact nobody checked.
    ///
    /// Everything else behaves as the performer step: additive, idempotent,
    /// strings untouched, unknown studios reported rather than invented.
    @discardableResult
    public func connectStudioEdges(dryRun: Bool = false) throws -> StudioConnectPlan {
        let assets = try fetchAllAssets()
        let known = Set(try fetchAllEntityProfiles().map(\.id))

        var associations = 0
        var missing = Set<String>()
        var conflicted: [UUID] = []
        var wanted: [(UUID, String)] = []

        for asset in assets {
            let studios = Set(asset.studios.filter { !$0.isEmpty })
            guard !studios.isEmpty else { continue }
            guard studios.count == 1, let name = studios.first else {
                conflicted.append(asset.id)
                continue
            }
            associations += 1
            let id = "studio:\(name)"
            if known.contains(id) { wanted.append((asset.id, id)) } else { missing.insert(name) }
        }

        let existingPairs: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT video_id, studio_id FROM video_studio")
                .map { "\($0["video_id"] as String)|\($0["studio_id"] as String)" })
        }
        let existing = existingPairs.count
        let notYetConnected = wanted.filter {
            !existingPairs.contains("\($0.0.uuidString)|\($0.1)")
        }.count

        if !dryRun {
            try dbQueue.write { db in
                for (videoId, studioId) in wanted {
                    // Provenance, same as the performer path. v29 added these
                    // columns and only that one path filled them, so studio and
                    // tag edges were being created with NULL provenance —
                    // D7 says every value carries its source, and an edge kind
                    // that quietly does not is worse than none doing it.
                    try db.execute(sql: """
                        INSERT INTO video_studio
                            (video_id, studio_id, source, recorded_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(video_id) DO UPDATE SET
                            studio_id = excluded.studio_id,
                            source = excluded.source,
                            recorded_at = excluded.recorded_at
                        """, arguments: [videoId.uuidString, studioId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
            }
        }

        return StudioConnectPlan(associations: associations,
                                 missingProfiles: missing.sorted(),
                                 alreadyConnected: existing,
                                 conflicted: conflicted,
                                 connectable: notYetConnected,
                                 skippedNoProfile: associations - wanted.count)
    }

    /// Videos whose studio edge disagrees with their strings.
    ///
    /// Videos carrying two studios are excluded: they are a known, reported
    /// blocker rather than a disagreement, and counting them here would mean
    /// verification could never pass while one existed.
    public func studioEdgeDisagreements() throws -> [UUID] {
        let assets = try fetchAllAssets()
        let known = Set(try fetchAllEntityProfiles().map(\.id))

        var disagreeing: [UUID] = []
        for asset in assets {
            let studios = Set(asset.studios.filter { !$0.isEmpty })
            guard studios.count == 1, let name = studios.first else { continue }
            let expected = known.contains("studio:\(name)") ? "studio:\(name)" : nil
            if try studioId(forVideo: asset.id) != expected { disagreeing.append(asset.id) }
        }
        return disagreeing
    }

    /// What connecting tags would do, split by what each tag turned out to be.
    public struct TagConnectPlan: Equatable, Sendable {
        /// Video associations that became real edges — action or video-attribute.
        ///
        /// ⚠️ Every wanted association, not just the new ones. That is why this
        /// figure equals the `video_tag` table total on a re-run and looks like
        /// the whole library was reconnected. `newVideoEdges` is what the run
        /// actually added.
        public let videoEdges: Int
        /// Performer associations that became real edges.
        public let performerEdges: Int
        /// Of `videoEdges`, the ones that did not already exist.
        public let newVideoEdges: Int
        /// Of `performerEdges`, the ones that did not already exist.
        public let newPerformerEdges: Int
        /// Associations staged because nobody has said what the tag describes.
        public let pending: Int
        /// ⚠️ PERFORMER attributes found on VIDEOS. Not edges, and deliberately
        /// not staged either: the decision is that enrichment corrects these per
        /// performer as each video is matched, because an attribute read off a
        /// video is a guess about which of its cast it describes.
        ///
        /// 🚨 A LIST, not a count. This was an `Int`, and the screen reported
        /// "90 performer traits sit on videos" with no way to find any of the
        /// ninety — the operator could not act on it at all. The same rule the
        /// batch runs already follow: *a tally you cannot act on is a dead
        /// end.* Keyed by tag, valued by how many videos carry it.
        public let attributeTagsOnVideos: [String: Int]

        /// Total associations, which is what the count used to be.
        public var attributeTagAssociations: Int {
            attributeTagsOnVideos.values.reduce(0, +)
        }
        /// Tags used by a video but absent from the vocabulary. Promotion should
        /// be run first; reported rather than created so the two steps stay
        /// separately checkable.
        public let unknownTags: [String]
    }

    /// Builds `video_tag` and `performer_tag` edges from the tag strings.
    ///
    /// ⚠️ The kind decides the destination, and there are four outcomes rather
    /// than two:
    ///
    /// | tag kind on a VIDEO | result |
    /// | --- | --- |
    /// | action, video-attribute | a `video_tag` edge |
    /// | performer-attribute | **nothing** — left for enrichment to correct |
    /// | unclassified | a pending association, so the link survives |
    /// | unknown to the vocabulary | reported |
    ///
    /// Additive, idempotent, and the strings are untouched.
    @discardableResult
    public func connectTagEdges(dryRun: Bool = false,
                                available: [TagKind] = TagKind.seed) throws -> TagConnectPlan {
        let assets = try fetchAllAssets()
        let profiles = try fetchAllEntityProfiles()
        let vocabulary = Dictionary(
            try fetchTagVocabulary().map { ($0.identityKey, $0) }, uniquingKeysWith: { a, _ in a })

        var videoEdges: [(UUID, String)] = []
        var performerEdges: [(String, String)] = []
        var pending: [(UUID, String)] = []
        var attributeOnVideo: [String: Int] = [:]
        var unknown = Set<String>()

        for asset in assets {
            for name in Set(asset.actions) where !name.isEmpty {
                let key = TagNormalizer.identityKey(name)
                guard let record = vocabulary[key] else { unknown.insert(name); continue }
                guard let kind = record.resolvedKind(from: available) else {
                    pending.append((asset.id, key)); continue
                }
                if kind.canAttach(to: .video) {
                    videoEdges.append((asset.id, key))
                } else {
                    // A performer attribute sitting on a video. Left alone,
                    // but RECORDED by tag so the operator can find them —
                    // `record.displayName` rather than the folded key, because
                    // the key is not what any screen shows.
                    attributeOnVideo[record.displayName, default: 0] += 1
                }
            }
        }

        for profile in profiles where profile.id.hasPrefix("actor:") {
            for name in Set(profile.tags) where !name.isEmpty {
                let key = TagNormalizer.identityKey(name)
                guard let record = vocabulary[key] else { unknown.insert(name); continue }
                guard let kind = record.resolvedKind(from: available) else { continue }
                if kind.canAttach(to: .performer) { performerEdges.append((profile.id, key)) }
            }
        }

        // Counted BEFORE the write, by intersection — after it, everything
        // looks already-connected and the run appears to have done nothing.
        let existingVideoTags: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT video_id, tag_id FROM video_tag")
                .map { "\($0["video_id"] as String)|\($0["tag_id"] as String)" })
        }
        let existingPerformerTags: Set<String> = try dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT performer_id, tag_id FROM performer_tag")
                .map { "\($0["performer_id"] as String)|\($0["tag_id"] as String)" })
        }
        let newVideoEdges = videoEdges.filter {
            !existingVideoTags.contains("\($0.0.uuidString)|\($0.1)")
        }.count
        let newPerformerEdges = performerEdges.filter {
            !existingPerformerTags.contains("\($0.0)|\($0.1)")
        }.count

        if !dryRun {
            try dbQueue.write { db in
                for (videoId, tagId) in videoEdges {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO video_tag
                            (video_id, tag_id, source, recorded_at) VALUES (?, ?, ?, ?)
                        """, arguments: [videoId.uuidString, tagId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
                for (performerId, tagId) in performerEdges {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO performer_tag
                            (performer_id, tag_id, source, recorded_at) VALUES (?, ?, ?, ?)
                        """, arguments: [performerId, tagId,
                                         EdgeProvenance.inferred.rawValue, Date()])
                }
                for (videoId, tagId) in pending {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO pending_tag_association (video_id, tag_id)
                        VALUES (?, ?)
                        """, arguments: [videoId.uuidString, tagId])
                }
            }
        }

        return TagConnectPlan(videoEdges: videoEdges.count,
                              performerEdges: performerEdges.count,
                              newVideoEdges: newVideoEdges,
                              newPerformerEdges: newPerformerEdges,
                              pending: pending.count,
                              attributeTagsOnVideos: attributeOnVideo,
                              unknownTags: unknown.sorted())
    }

    /// Turns a tag's staged associations into edges, now that it has a kind.
    ///
    /// The other half of `pending_tag_association`: a parser finding that was
    /// held rather than lost is redeemed here. An association whose kind turns
    /// out to describe the other node type is DISCARDED and counted — that is
    /// the attribute-on-a-video case, and inventing an edge for it is exactly
    /// what the taxonomy exists to stop.
    ///
    /// - Returns: how many became edges, and how many were dropped.
    @discardableResult
    public func resolvePendingAssociations(forTag tagId: String,
                                           available: [TagKind] = TagKind.seed)
    throws -> (materialised: Int, discarded: Int) {
        let record = try fetchTagVocabulary().first { $0.identityKey == tagId }
        guard let kind = record?.resolvedKind(from: available) else { return (0, 0) }

        let videoIds: [String] = try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT video_id FROM pending_tag_association WHERE tag_id = ?", arguments: [tagId])
        }
        guard !videoIds.isEmpty else { return (0, 0) }

        let becomesEdge = kind.canAttach(to: .video)
        try dbQueue.write { db in
            if becomesEdge {
                for videoId in videoIds {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO video_tag (video_id, tag_id) VALUES (?, ?)
                        """, arguments: [videoId, tagId])
                }
            }
            try db.execute(sql: "DELETE FROM pending_tag_association WHERE tag_id = ?",
                           arguments: [tagId])
        }
        return becomesEdge ? (videoIds.count, 0) : (0, videoIds.count)
    }

    // MARK: - Tags arriving on people

    /// Registers and connects the tags carried by actor profiles.
    ///
    /// ⚠️ A tag arriving ON A PERSON is known to describe a person — that is
    /// what the file it came from means. So an unknown one is created as a
    /// performer attribute rather than left unclassified, which is the one
    /// place the taxonomy can be inferred instead of asked about.
    ///
    /// Built for the CSV round-trip, which saved profiles and stopped: the tags
    /// landed as bare strings with no vocabulary record and no edge, so an
    /// enriched file made the graph no better than before it ran.
    ///
    /// Never reclassifies. A tag already known as something else keeps its
    /// kind, and simply gets no edge here — the arriving file does not outrank
    /// a decision already made.
    @discardableResult
    public func connectPerformerTags(for profileIds: [String],
                                     available: [TagKind] = TagKind.seed) throws
    -> (created: Int, linked: Int) {
        var created = 0, linked = 0
        var vocabulary = try fetchTagVocabulary()

        for id in profileIds where id.hasPrefix("actor:") {
            guard let profile = try fetchEntityProfile(for: id) else { continue }
            for raw in Set(profile.tags) where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = TagNormalizer.identityKey(raw)
                var record = vocabulary.first { $0.identityKey == key }

                if record == nil {
                    let new = TagRecord(displayName: raw, kind: .performerAttribute)
                    try saveTagRecord(new)
                    vocabulary.append(new)
                    record = new
                    created += 1
                }

                guard let kind = record?.resolvedKind(from: available),
                      kind.canAttach(to: .performer) else { continue }
                try linkTag(key, toPerformer: id)
                linked += 1
            }
        }
        return (created, linked)
    }

    // MARK: - The edges that travel between libraries

    /// Performer traits, as portable pairs. Names no video, so it means the
    /// same thing in any library — see `GraphSync`.
    public func performerTagPairs() throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT performer_id, tag_id FROM performer_tag")
                .map { GraphEdgePair(from: $0["performer_id"], to: $0["tag_id"]) }
        }
    }

    /// Which network owns which imprint, **as things stand now**.
    ///
    /// ⚠️ Current rows only. Every existing caller means "now", so "now" is the
    /// default and no call site changed when the table became temporal. A
    /// retired 2009 hierarchy must not be reported as a dangling parent
    /// forever, which is what including closed rows would do.
    public func studioParentPairs() throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT studio_id, parent_studio_id FROM studio_parent
                 WHERE valid_to IS NULL
                """)
                .map { GraphEdgePair(from: $0["studio_id"], to: $0["parent_studio_id"]) }
        }
    }

    /// The hierarchy as it stood on a given day.
    ///
    /// ⚠️ A row with `valid_from = NULL` matches ANY date at or before its
    /// `valid_to`. NULL means "as far back as we know", not "never" — and since
    /// every row migrated by v30 carries NULL, reading it as "no match" would
    /// make the entire existing hierarchy vanish from as-of queries the day
    /// this shipped.
    public func studioParentPairs(asOf day: String) throws -> [GraphEdgePair] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT studio_id, parent_studio_id FROM studio_parent
                 WHERE (valid_from IS NULL OR valid_from <= ?)
                   AND (valid_to   IS NULL OR valid_to   >  ?)
                """, arguments: [day, day])
                .map { GraphEdgePair(from: $0["studio_id"], to: $0["parent_studio_id"]) }
        }
    }

    /// The hierarchy WITH its dates and its history — what a sync carries.
    ///
    /// ⚠️ Every period, not just the open one. `studioParentPairs()` answers
    /// "who owns this now", which is right for every reader inside this library
    /// and wrong for an export: a former ownership the operator recorded by hand
    /// is the scarcest fact in the graph, and dropping it means it can never
    /// reach the other library.
    public func studioParentEdges() throws -> [StudioParentEdge] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT studio_id, parent_studio_id, valid_from, valid_to
                  FROM studio_parent
                 ORDER BY studio_id, valid_from IS NULL DESC, valid_from
                """)
                .map { StudioParentEdge(from: $0["studio_id"], to: $0["parent_studio_id"],
                                        validFrom: $0["valid_from"], validTo: $0["valid_to"]) }
        }
    }

    /// Gives the CURRENT ownership a start date it did not have.
    ///
    /// ⚠️ Only ever fills a gap. Refuses when a start is already recorded — a
    /// date this library holds is an answer, and replacing it would be the same
    /// silent overrule the merge exists to avoid.
    @discardableResult
    public func setStudioParentStart(_ from: String, forStudio studioId: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE studio_parent SET valid_from = ?
                 WHERE studio_id = ? AND valid_to IS NULL AND valid_from IS NULL
                """, arguments: [from, studioId])
            return db.changesCount > 0
        }
    }

    /// Records a FORMER ownership — a period that has already ended.
    ///
    /// ⚠️ Closed periods only. An open period is `setStudioParent`'s business,
    /// because it has to close whatever it replaces; this one adds history
    /// beside the current row and touches nothing else.
    ///
    /// ⭐ No cycle check, deliberately. The walk in `setStudioParent` follows
    /// **current** rows, and a period that has ended cannot put a studio inside
    /// its own present hierarchy.
    public func addStudioParentPeriod(_ parentId: String, forStudio studioId: String,
                                      from: String?, to: String,
                                      source: EdgeProvenance = .download) throws {
        guard studioId != parentId else { throw GraphEdgeError.cycle(path: [studioId]) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO studio_parent
                    (studio_id, parent_studio_id, valid_from, valid_to, source, recorded_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [studioId, parentId, from, to, source.rawValue, Date()])
        }
    }

    /// The day part of a date, as the hierarchy stores it.
    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Connecting one video

    /// Builds the edges for a SINGLE video from its own strings.
    ///
    /// Same routing as the bulk connect — a credit with no profile is skipped,
    /// two studios cannot be represented, a tag goes where its kind says — but
    /// scoped to one record so a video arriving from elsewhere can be wired in
    /// without re-scanning the library.
    ///
    /// ⚠️ Exists because a moved video is created under a NEW id in the
    /// destination. Edges point at ids, so none of the source's edges can
    /// follow it, and without this the video would sit in its new library with
    /// its text intact and no place in the graph until someone happened to run
    /// a full connect.
    @discardableResult
    public func connectEdges(forVideo videoId: UUID,
                             available: [TagKind] = TagKind.seed) throws -> Int {
        guard let asset = try fetchAllAssets().first(where: { $0.id == videoId }) else { return 0 }
        let profiles = Set(try fetchAllEntityProfiles().map(\.id))
        let vocabulary = try fetchTagVocabulary()
        var written = 0

        for name in Set(asset.actors) where profiles.contains("actor:\(name)") {
            try linkPerformer("actor:\(name)", toVideo: videoId)
            written += 1
        }

        // One studio only. Two is the conflict the schema refuses, and picking
        // one here would make a move quietly resolve something the dedicated
        // screen exists to put in front of a person.
        let studios = Set(asset.studios.filter { !$0.isEmpty })
        if studios.count == 1, let name = studios.first, profiles.contains("studio:\(name)") {
            try setStudio("studio:\(name)", forVideo: videoId)
            written += 1
        }

        for raw in Set(asset.actions) {
            let key = TagNormalizer.identityKey(raw)
            guard let record = vocabulary.first(where: { $0.identityKey == key }) else { continue }
            guard let kind = record.resolvedKind(from: available) else {
                // Held rather than dropped, exactly as the bulk connect does.
                try addPendingTagAssociation(key, forVideo: videoId)
                continue
            }
            // A trait describing a person is left alone: which of the cast it
            // refers to is a guess, and a move must not be where that guess
            // gets made.
            guard kind.canAttach(to: .video) else { continue }
            try linkTag(key, toVideo: videoId)
            written += 1
        }
        return written
    }

    // MARK: - Reading across both representations
    //
    // ⚠️ Between connecting and retiring, a video's cast lives partly in edges
    // and partly in the legacy strings. Reads must not see either half alone,
    // or the same library answers differently depending on how far the
    // migration has run — and browse, filter and counts would shift under the
    // operator while nothing they did caused it.
    //
    // The union is what lets step 5 retire a string WITHOUT changing an answer:
    // the edge already says the same thing, so removing the string is invisible.
    // That property is the gate, and it is what these exist to make testable.

    /// A video's performers, from edges and strings together.
    public func resolvedPerformerIds(forVideo videoId: UUID, in asset: Asset? = nil)
    throws -> Set<String> {
        let fromEdges = Set(try performerIds(forVideo: videoId))
        let source = try asset ?? fetchAllAssets().first { $0.id == videoId }
        let fromStrings = Set((source?.actors ?? []).map { "actor:\($0)" })
        return fromEdges.union(fromStrings)
    }

    /// A video's releasing studio.
    ///
    /// The EDGE wins where one exists: it is the representation the schema
    /// constrains, and a video the strings gave two studios has no edge at all
    /// — so falling back to the strings there would hand back an arbitrary one
    /// of the two, which is the choice this migration refuses to make.
    public func resolvedStudioId(forVideo videoId: UUID, in asset: Asset? = nil)
    throws -> String? {
        if let edge = try studioId(forVideo: videoId) { return edge }
        let source = try asset ?? fetchAllAssets().first { $0.id == videoId }
        let studios = Set((source?.studios ?? []).filter { !$0.isEmpty })
        guard studios.count == 1, let name = studios.first else { return nil }
        return "studio:\(name)"
    }

    /// A video's tags, folded so two spellings of one tag answer once.
    ///
    /// ⚠️ Deliberately does NOT include pending associations. A staged tag is
    /// not attached to anything yet — that is the whole point of staging it —
    /// and surfacing it here would put an unclassified tag back on the video by
    /// a different route.
    public func resolvedTagIds(forVideo videoId: UUID, in asset: Asset? = nil)
    throws -> Set<String> {
        let fromEdges = Set(try tagIds(forVideo: videoId))
        let source = try asset ?? fetchAllAssets().first { $0.id == videoId }
        let fromStrings = Set((source?.actions ?? []).map(TagNormalizer.identityKey))
        return fromEdges.union(fromStrings)
    }

    // MARK: - Retiring the strings

    /// Whether a tag's strings can be dropped: every video that carries it in a
    /// string also carries it as an edge.
    ///
    /// ⚠️ Scoped PER TAG. Gating the whole cleanup on "every tag is classified"
    /// would let one stubborn tag freeze the legacy representation for the
    /// entire library indefinitely; per tag, the migration makes progress the
    /// whole way there.
    ///
    /// A tag classified as describing a PERFORMER is never retirable from
    /// videos: its associations were deliberately not turned into edges, and
    /// dropping the strings would destroy the record that enrichment still has
    /// work to do.
    public func canRetireStrings(forTag tagId: String,
                                 available: [TagKind] = TagKind.seed) throws -> Bool {
        guard let record = try fetchTagVocabulary().first(where: { $0.identityKey == tagId }),
              let kind = record.resolvedKind(from: available),
              kind.canAttach(to: .video)
        else { return false }

        let pending = try dbQueue.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM pending_tag_association WHERE tag_id = ?",
                arguments: [tagId]) ?? 0
        }
        guard pending == 0 else { return false }

        let edged = Set(try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT video_id FROM video_tag WHERE tag_id = ?",
                                arguments: [tagId])
        })
        for asset in try fetchAllAssets() {
            let carriesString = asset.actions.contains { TagNormalizer.identityKey($0) == tagId }
            if carriesString && !edged.contains(asset.id.uuidString) { return false }
        }
        return true
    }

    // MARK: - Resetting match status

    /// What a reset would affect, counted before anything is written.
    ///
    /// Separate from performing it because this is destructive over the whole
    /// library, and a number you can read beforehand is the difference between
    /// a decision and a surprise.
    public struct MatchResetPlan: Equatable, Sendable {
        /// Videos the source matched. Re-deriving these costs a re-run.
        public let matched: Int
        /// Videos a PERSON ruled out. Re-deriving these is impossible —
        /// nothing but the operator knows they looked.
        public let ruledOut: Int
        /// Searched but unresolved: no match, ambiguous, needs review.
        public let unresolved: Int

        public var clearable: Int { matched + unresolved }
        public var total: Int { matched + ruledOut + unresolved }
    }

    public func planMatchReset() throws -> MatchResetPlan {
        try dbQueue.read { db in
            func count(_ clause: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE \(clause)") ?? 0
            }
            return MatchResetPlan(
                matched: try count("enrichment_state = 'matched'"),
                ruledOut: try count("enrichment_state = 'unmatchable'"),
                unresolved: try count("""
                    enrichment_state IS NOT NULL
                    AND enrichment_state NOT IN ('matched', 'unmatchable')
                    """))
        }
    }

    /// Clears the record of having been matched, so videos return to the queue.
    ///
    /// ⚠️ Clears ONLY the match bookkeeping — state, source, source id, link and
    /// timestamp. Every value a match ever wrote is left exactly as it is:
    /// release date, cast, studio, title, tags. Those are the library's
    /// records, not the match's, and re-deriving them is what the re-run is
    /// for. A reset that emptied them would be a data loss dressed as a retry.
    ///
    /// ⚠️ `includingRuledOut` defaults to FALSE, and should stay false unless
    /// there is a reason. `unmatchable` means a person looked and concluded the
    /// source has no record — the one state a machine never assigns. Clearing
    /// it returns those videos to a queue they were deliberately removed from,
    /// and nothing can re-derive the judgement.
    ///
    /// Written in SQL rather than by loading every asset: this runs over the
    /// whole library, and decoding two thousand records to null five columns is
    /// a cost with nothing to show for it.
    ///
    /// - Returns: how many rows were cleared.
    @discardableResult
    public func resetMatchStatus(includingRuledOut: Bool = false) throws -> Int {
        try dbQueue.write { db in
            let keepRuledOut = includingRuledOut
                ? ""
                : "AND enrichment_state IS NOT 'unmatchable'"
            try db.execute(sql: """
                UPDATE assets SET
                    enrichment_state = NULL,
                    enrichment_source = NULL,
                    enrichment_source_id = NULL,
                    enrichment_url = NULL,
                    enrichment_checked_at = NULL
                WHERE enrichment_state IS NOT NULL \(keepRuledOut)
                """)
            return db.changesCount
        }
    }

    // MARK: - Graph edges
    //
    // ⚠️ Every one of these can THROW on a constraint, and that is the point.
    // A second studio on a video, a duplicate edge, a studio as its own parent
    // — the schema refuses them, so callers get an error instead of the graph
    // quietly acquiring something impossible.

    /// Credits a performer on a video. Idempotent: crediting twice is one edge.
    ///
    /// - Parameter source: where the credit came from. Defaults to `inferred`
    ///   because the callers that predate edge attributes are rewiring from
    ///   strings; a caller that knows better should say so.
    public func linkPerformer(_ performerId: String, toVideo videoId: UUID,
                              source: EdgeProvenance = .inferred) throws {
        try dbQueue.write { db in
            // Bound, not interpolated. The value is a fixed enum today and
            // interpolating it would still be a habit worth not having in a
            // file this size.
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_performer
                    (video_id, performer_id, source, recorded_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [videoId.uuidString, performerId,
                                 source.rawValue, Date()])
        }
    }

    /// Sets the releasing studio, REPLACING any existing one.
    ///
    /// A scene has one releasing studio, so this is an assignment rather than
    /// an addition — and the primary key means a caller cannot accidentally
    /// make it an addition.
    public func setStudio(_ studioId: String, forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO video_studio (video_id, studio_id) VALUES (?, ?)
                ON CONFLICT(video_id) DO UPDATE SET studio_id = excluded.studio_id
                """, arguments: [videoId.uuidString, studioId])
        }
    }

    /// Attaches a tag to a video. `tagId` is the folded identity key.
    public func linkTag(_ tagId: String, toVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_tag (video_id, tag_id) VALUES (?, ?)
                """, arguments: [videoId.uuidString, tagId])
        }
    }

    public func linkTag(_ tagId: String, toPerformer performerId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO performer_tag (performer_id, tag_id) VALUES (?, ?)
                """, arguments: [performerId, tagId])
        }
    }

    /// Records that `studioId` belongs to `parentId`.
    ///
    /// ⚠️ Refuses a cycle — a studio that would become its own ancestor. Not
    /// expressible as a SQLite constraint, and without it a parent-studio
    /// filter recurses forever.
    /// - Parameters:
    ///   - since: when the new ownership began. `nil` means "as far back as we
    ///     know", which is the honest value when a source names a parent but no
    ///     date — which is every source seen so far.
    ///
    /// ⚠️ A CHANGE of parent closes the previous row rather than overwriting
    /// it. The old ownership was true; it stopped being true. Overwriting threw
    /// that away, which is the whole reason for the temporal shape.
    ///
    /// ⚠️ Re-asserting the SAME parent is a no-op, not a new row. Match runs
    /// re-assert constantly, and each one opening a period would fill the table
    /// with adjacent identical rows.
    public func setStudioParent(_ parentId: String, forStudio studioId: String,
                                since: String? = nil,
                                source: EdgeProvenance = .download) throws {
        guard studioId != parentId else { throw GraphEdgeError.cycle(path: [studioId]) }

        var seen = [studioId]
        var current: String? = parentId
        while let id = current {
            if seen.contains(id) { throw GraphEdgeError.cycle(path: seen + [id]) }
            seen.append(id)
            // The CURRENT parent — a closed historical row must not make a
            // hierarchy look cyclic when it is only a former owner.
            current = try dbQueue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT parent_studio_id FROM studio_parent
                     WHERE studio_id = ? AND valid_to IS NULL
                    """, arguments: [id])
            }
        }

        try dbQueue.write { db in
            let existing = try String.fetchOne(db, sql: """
                SELECT parent_studio_id FROM studio_parent
                 WHERE studio_id = ? AND valid_to IS NULL
                """, arguments: [studioId])

            if existing == parentId { return }

            // 🚨 The boundary is ONE date used twice, so the periods meet.
            //
            // Closing the old row at today while inserting the new one with
            // `valid_from = NULL` made the new period cover all of history —
            // and `studioParentPairs(asOf:)` then returned BOTH parents for any
            // past date, breaking the one-parent-at-a-time invariant the whole
            // temporal shape exists to hold. Found by an independent audit,
            // 2026-08-07; the existing tests missed it by always passing an
            // explicit `since`.
            //
            // NULL stays correct for a FIRST parent — "as far back as we know"
            // — and is only wrong when it follows something.
            let boundary = since ?? Self.isoDay(Date())

            if existing != nil {
                try db.execute(sql: """
                    UPDATE studio_parent SET valid_to = ?
                     WHERE studio_id = ? AND valid_to IS NULL
                    """, arguments: [boundary, studioId])
            }

            try db.execute(sql: """
                INSERT INTO studio_parent
                    (studio_id, parent_studio_id, valid_from, valid_to, source, recorded_at)
                VALUES (?, ?, ?, NULL, ?, ?)
                """, arguments: [studioId, parentId,
                                 existing == nil ? since : boundary,
                                 source.rawValue, Date()])
        }
    }

    /// Stages a tag found with no edge context — not an edge, and invisible to
    /// every graph query until someone says what the tag describes.
    public func addPendingTagAssociation(_ tagId: String, forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO pending_tag_association (video_id, tag_id) VALUES (?, ?)
                """, arguments: [videoId.uuidString, tagId])
        }
    }

    // MARK: Reading the graph

    /// Records how a performer was credited in one video.
    ///
    /// ⚠️ Upserts the ATTRIBUTES onto an existing edge rather than replacing
    /// the edge. The edge itself is `(video, performer)` and does not change;
    /// what a match learns is how they were billed and where that came from.
    ///
    /// ⚠️ A nil argument leaves the stored value alone rather than clearing it
    /// — the same rule as `ProposedField`, where "the source said nothing" must
    /// never overwrite something already known (D5).
    public func recordPerformerCredit(_ credit: PerformerCredit,
                                      forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_performer (video_id, performer_id)
                VALUES (?, ?)
                """, arguments: [videoId.uuidString, credit.performerId])
            try db.execute(sql: """
                UPDATE video_performer
                   SET credited_as = COALESCE(?, credited_as),
                       billing     = COALESCE(?, billing),
                       source      = COALESCE(?, source),
                       recorded_at = ?
                 WHERE video_id = ? AND performer_id = ?
                """, arguments: [credit.creditedAs, credit.billing,
                                 credit.source?.rawValue, Date(),
                                 videoId.uuidString, credit.performerId])
        }
    }

    /// Writes an edge the way the code did before v29 existed: no provenance.
    ///
    /// ⚠️ Internal and for tests only. There is deliberately no public path to
    /// an unstamped edge — every writer now records where it got it — but a
    /// migrated library is full of them, and the read path's handling of that
    /// is worth asserting rather than assuming.
    ///
    /// Lives here because `dbQueue` is private to this file and stays that way.
    func insertLegacyPerformerEdge(_ performerId: String, forVideo videoId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO video_performer (video_id, performer_id) VALUES (?, ?)
                """, arguments: [videoId.uuidString, performerId])
        }
    }

    /// Every credit on a video, with whatever is known about each.
    ///
    /// Ordered by billing where the source stated it, then by id so the result
    /// is stable — a list that reorders between reads looks like data changing.
    public func performerCredits(forVideo videoId: UUID) throws -> [PerformerCredit] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT performer_id, credited_as, billing, source
                  FROM video_performer
                 WHERE video_id = ?
                 ORDER BY billing IS NULL, billing, performer_id
                """, arguments: [videoId.uuidString])
                .map { row in
                    PerformerCredit(
                        performerId: row["performer_id"],
                        creditedAs: row["credited_as"],
                        billing: row["billing"],
                        source: (row["source"] as String?).flatMap(EdgeProvenance.init(rawValue:)))
                }
        }
    }

    /// How many edges of one kind carry each provenance.
    ///
    /// The figure that makes phase 1 worth having: it says how much of the
    /// graph is asserted by a source and how much was derived from strings —
    /// a question nothing could answer before.
    public func edgeProvenanceCounts(_ kind: GraphEdgeKind) throws -> [String: Int] {
        try dbQueue.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT COALESCE(source, 'unknown') AS s, COUNT(*) AS n
                  FROM \(kind.rawValue) GROUP BY s
                """) {
                counts[row["s"]] = row["n"]
            }
            return counts
        }
    }

    public func performerIds(forVideo videoId: UUID) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT performer_id FROM video_performer WHERE video_id = ? ORDER BY performer_id
                """, arguments: [videoId.uuidString])
        }
    }

    public func studioId(forVideo videoId: UUID) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT studio_id FROM video_studio WHERE video_id = ?",
                                arguments: [videoId.uuidString])
        }
    }

    /// The whole `video_studio` edge in one read.
    ///
    /// The audit asks about every video, and doing that through
    /// `studioId(forVideo:)` is one query per video — 2,104 of them on the
    /// drive library, each taking the read lock. One table scan instead.
    public func studioIdsByVideo() throws -> [UUID: String] {
        try dbQueue.read { db in
            var result: [UUID: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT video_id, studio_id FROM video_studio") {
                guard let id = UUID(uuidString: row["video_id"]) else { continue }
                result[id] = row["studio_id"]
            }
            return result
        }
    }

    /// Everything wrong with this library's studios.
    ///
    /// Gathers what `StudioAudit` needs and hands it over. The reads are all
    /// whole-table on purpose: the audit's questions are about the library
    /// entire, and asking them per record is what made an earlier version of
    /// `promoteStudioProfiles` unusable with the external drive attached.
    public func auditStudios() throws -> [StudioCheck] {
        let profiles = try fetchAllEntityProfiles()
        return StudioAudit.run(StudioAudit.Input(
            assets: try fetchAllAssets(),
            profileIds: Set(profiles.map(\.id)),
            confirmedStudioIds: Set(profiles
                .filter { $0.id.hasPrefix("studio:") && $0.enrichmentState == .matched }
                .map(\.id)),
            studioIdByVideo: try studioIdsByVideo(),
            parentPairs: try studioParentPairs()))
    }

    /// Data that is wrong, found by joining records that disagree.
    ///
    /// Whole-table reads, like `auditStudios`: the questions are about the
    /// library entire, and asking them per record is what made an earlier
    /// version of `promoteStudioProfiles` unusable with the drive attached.
    public func auditGraph() throws -> [GraphCheck] {
        let profiles = try fetchAllEntityProfiles()
        return GraphAudit.run(GraphAudit.Input(
            assets: try fetchAllAssets(),
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })))
    }

    public func tagIds(forVideo videoId: UUID) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT tag_id FROM video_tag WHERE video_id = ? ORDER BY tag_id",
                arguments: [videoId.uuidString])
        }
    }

    /// Videos featuring a performer — one query, where it used to be a scan of
    /// every asset in the library with the names compared by hand.
    public func videoIds(forPerformer performerId: String) throws -> [UUID] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT video_id FROM video_performer WHERE performer_id = ?",
                arguments: [performerId])
        }.compactMap(UUID.init(uuidString:))
    }

    /// Videos per studio, keyed by node id, counted from the TAGS.
    ///
    /// ⚠️ Deliberately not from `video_studio`. These counts sit beside links
    /// that pivot the grid, and the grid filters on the `studio:` string — so
    /// counting edges would print a number the very next click contradicts.
    /// The edge is the better representation and the string is what is
    /// displayed; until writes move to the edge, the display must agree with
    /// itself.
    public func studioVideoCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT j.value AS studio, COUNT(DISTINCT assets.id) AS n
                FROM assets, json_each(assets.tags) j
                WHERE j.value LIKE 'studio:_%'
                GROUP BY j.value
                """) {
                counts[row["studio"]] = row["n"]
            }
            return counts
        }
    }

    /// A studio's network, its sibling imprints and its own imprints.
    public func studioLineage(for studioId: String) throws -> StudioLineage {
        StudioLineage.build(for: studioId,
                            pairs: try studioParentPairs(),
                            videoCounts: try studioVideoCounts())
    }

    /// The imprints directly beneath a network — one level, not the whole tree.
    ///
    /// Lifted out of `studioIdWithDescendants` so a profile page can ask what a
    /// studio's children are without walking every generation under it. The
    /// page shows one level; the walk exists for filtering.
    public func childStudioIds(of studioId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT studio_id FROM studio_parent
                WHERE parent_studio_id = ? AND valid_to IS NULL
                ORDER BY studio_id
                """, arguments: [studioId])
        }
    }

    /// The network a studio belongs to now, if one is recorded.
    public func parentStudioId(of studioId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT parent_studio_id FROM studio_parent
                 WHERE studio_id = ? AND valid_to IS NULL
                """, arguments: [studioId])
        }
    }

    /// Opens a second period without closing the first, the way an incautious
    /// second writer would.
    ///
    /// ⚠️ Internal and for tests only. It exists to prove the **database**
    /// refuses this, rather than the application remembering to — a rule
    /// enforced only in `setStudioParent` would be one merge path away from
    /// being broken.
    func insertOpenStudioParentForTesting(_ parentId: String,
                                          forStudio studioId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO studio_parent (studio_id, parent_studio_id, valid_from, valid_to)
                VALUES (?, ?, NULL, NULL)
                """, arguments: [studioId, parentId])
        }
    }

    /// Every network this studio has belonged to, oldest first.
    ///
    /// What the temporal shape buys on a profile page: *"Part of X since 2015,
    /// previously Y"* is a fact about a company and was unrepresentable before.
    public func studioParentHistory(of studioId: String) throws -> [StudioParentPeriod] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT parent_studio_id, valid_from, valid_to FROM studio_parent
                 WHERE studio_id = ?
                 ORDER BY valid_from IS NULL DESC, valid_from
                """, arguments: [studioId])
                .map { StudioParentPeriod(parentId: $0["parent_studio_id"],
                                          from: $0["valid_from"], to: $0["valid_to"]) }
        }
    }

    /// Videos released by a studio — the studio counterpart of
    /// `videoIds(forPerformer:)`, which did not exist because `video_studio`
    /// was only ever queried in the video direction.
    public func videoIds(forStudio studioId: String) throws -> [UUID] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT video_id FROM video_studio WHERE studio_id = ?",
                arguments: [studioId])
        }.compactMap(UUID.init(uuidString:))
    }

    /// A studio and every studio beneath it, so a filter on a network finds the
    /// imprints that belong to it.
    ///
    /// - Parameter asOf: the day to resolve ownership on. `nil` means now.
    ///
    /// ⭐ The as-of form is what stops the family view being an anachronism: a
    /// 2012 release belongs to the network that owned its imprint in 2012, not
    /// to whoever bought it in 2018.
    public func studioIdWithDescendants(_ studioId: String,
                                        asOf: String? = nil) throws -> [String] {
        var found = [studioId]
        var frontier = [studioId]
        while !frontier.isEmpty {
            let placeholders = frontier.map { _ in "?" }.joined(separator: ",")
            let children: [String] = try dbQueue.read { db in
                if let asOf {
                    return try String.fetchAll(db, sql: """
                        SELECT studio_id FROM studio_parent
                        WHERE parent_studio_id IN (\(placeholders))
                          AND (valid_from IS NULL OR valid_from <= ?)
                          AND (valid_to   IS NULL OR valid_to   >  ?)
                        """, arguments: StatementArguments(frontier + [asOf, asOf]))
                }
                return try String.fetchAll(db, sql: """
                    SELECT studio_id FROM studio_parent
                    WHERE parent_studio_id IN (\(placeholders))
                      AND valid_to IS NULL
                    """, arguments: StatementArguments(frontier))
            }
            // A cycle cannot be created through setStudioParent, but a database
            // edited by hand is not bound by that — so the walk stops rather
            // than looping.
            frontier = children.filter { !found.contains($0) }
            found.append(contentsOf: frontier)
        }
        return found
    }

    /// Counts, for asserting a migration reproduced what the strings said.
    public func edgeCount(_ kind: GraphEdgeKind) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(kind.rawValue)") ?? 0
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
        let discovered = TagVocabulary.promoting(try fetchAllAssets())
        let known = Set(try fetchTagVocabulary().map(\.identityKey))
        let new = discovered.filter { !known.contains($0.identityKey) }

        try dbQueue.write { db in
            for record in new { try record.insert(db) }
        }
        return new
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
    public func confirmStudio(_ name: String, source: String?) throws {
        let id = "studio:\(name)"
        var profile = try fetchEntityProfile(for: id) ?? EntityProfile(id: id)
        guard profile.enrichmentState != .matched else { return }

        profile.enrichmentState = .matched
        profile.enrichmentSource = source
        profile.enrichmentCheckedAt = Date()
        try saveEntityProfile(profile)
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

