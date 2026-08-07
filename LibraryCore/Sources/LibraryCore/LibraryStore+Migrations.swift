// LibraryStore+Migrations.swift
// The schema, version by version.
//
// Split out of `LibraryStore.swift` on 2026-08-07: it was 2,769 lines, roughly
// a fifth of it this, and every session added more. Nothing here changed in the
// move — the ordering below is load-bearing and is reproduced verbatim.
//
// 🚨 MIGRATIONS RUN IN REGISTRATION ORDER, NOT NAME ORDER. The sequence below
// is already out of numeric sequence (…v19, v23, v22, v21, v24, v26, v27, v20…)
// because each was appended as it was written. GRDB replays them in the order
// they are registered here, so a library migrated under the old order and one
// migrated under a "tidied" order would end up with different schemas.
//
// APPEND. Never reorder, never renumber, and never insert into the middle.

import Foundation
import GRDB

extension LibraryStore {

    func migrate() throws {
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
}
