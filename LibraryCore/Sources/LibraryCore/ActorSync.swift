// ActorSync.swift
// The engine behind "Sync Actors" for the multi-library session: an explicit,
// user-driven convergence of selected actors across every open library.
// Galleries union (content-hash deduped), blanks fill, list fields union, and
// TRUE conflicts (both sides holding different real values) are never resolved
// silently — the planner surfaces them and the caller supplies a resolution
// (pick one side, or Keep Both for the comma-separated multi-value fields).
//
// The apply path deliberately reuses `applyActorMerge`: the converged record
// becomes the merge SOURCE for each library, so field semantics, photo
// dedupe/adoption, and the Phase-3 single transaction all carry over. A
// conflict the user chose to skip is encoded as nil in the converged record —
// which `applyActorMerge` already treats as "keep the destination's value".
//
// Deletions DO propagate, via tombstones (v20). Sync otherwise compares what
// each library holds, which cannot distinguish "never had it" from "deleted
// it" — so a union silently resurrects removed actors, and renames (a delete
// plus a create) bring the old name back from the other side.
// See plans/actor-sync.md.

import Foundation

// MARK: - Fields

/// The scalar profile fields sync reasons about (tags/AKAs/galleries always
/// union and never conflict).
public enum ActorSyncField: String, CaseIterable, Sendable {
    case bio, homePage, gender, hairColor, tattoos, piercings, birthYear, countryOfOrigin, rating
    // Career span (v17). Without these, syncing two libraries would leave
    // career data behind in whichever one happened to have it.
    case birthDate, careerSpanRaw, careerStartYear, careerEndYear, ageAtCareerStart
    // Enrichment state (v18). Without these, one library's lookup results never
    // reach another and the same actors get re-checked.
    case enrichmentState, enrichmentSource

    /// Comma-separated multi-value fields: the data model (and the filter
    /// engine, which splits on commas) already treats these as sets, so a
    /// conflict here can be resolved with "Keep Both".
    public var isMultiValue: Bool {
        self == .gender || self == .hairColor || self == .countryOfOrigin
    }

    public var displayName: String {
        switch self {
        case .bio: return "Bio"
        case .homePage: return "Home Page"
        case .gender: return "Gender"
        case .hairColor: return "Hair Color"
        case .tattoos: return "Tattoos"
        case .piercings: return "Piercings"
        case .birthYear: return "Birth Year"
        case .countryOfOrigin: return "Country"
        case .rating: return "Rating"
        case .birthDate: return "Birth Date"
        case .careerSpanRaw: return "Career Span (source text)"
        case .careerStartYear: return "Career Start"
        case .careerEndYear: return "Career End"
        case .ageAtCareerStart: return "Age at Career Start"
        case .enrichmentState: return "Enrichment Result"
        case .enrichmentSource: return "Enrichment Source"
        }
    }

    func value(in profile: EntityProfile) -> String? {
        let raw: String?
        switch self {
        case .bio: raw = profile.bio
        case .homePage: raw = profile.homePage
        case .gender: raw = profile.gender
        case .hairColor: raw = profile.hairColor
        case .tattoos: raw = profile.tattoos
        case .piercings: raw = profile.piercings
        case .birthYear: raw = profile.birthYear.map(String.init)
        case .countryOfOrigin: raw = profile.countryOfOrigin
        case .rating: raw = profile.rating.map(String.init)
        case .birthDate: raw = profile.birthDate
        case .careerSpanRaw: raw = profile.careerSpanRaw
        case .careerStartYear: raw = profile.careerStartYear.map(String.init)
        case .careerEndYear: raw = profile.careerEndYear.map(String.init)
        case .ageAtCareerStart: raw = profile.ageAtCareerStart.map(String.init)
        case .enrichmentState: raw = profile.enrichmentState?.rawValue
        case .enrichmentSource: raw = profile.enrichmentSource
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func apply(_ value: String?, to profile: inout EntityProfile) {
        switch self {
        case .bio: profile.bio = value
        case .homePage: profile.homePage = value
        case .gender: profile.gender = value
        case .hairColor: profile.hairColor = value
        case .tattoos: profile.tattoos = value
        case .piercings: profile.piercings = value
        case .birthYear: profile.birthYear = value.flatMap(Int.init)
        case .countryOfOrigin: profile.countryOfOrigin = value
        case .rating: profile.rating = value.flatMap(Int.init)
        case .birthDate: profile.birthDate = value
        case .careerSpanRaw: profile.careerSpanRaw = value
        case .careerStartYear: profile.careerStartYear = value.flatMap(Int.init)
        case .careerEndYear: profile.careerEndYear = value.flatMap(Int.init)
        case .ageAtCareerStart: profile.ageAtCareerStart = value.flatMap(Int.init)
        case .enrichmentState: profile.enrichmentState = value.flatMap(EnrichmentState.init(rawValue:))
        case .enrichmentSource: profile.enrichmentSource = value
        }
    }
}

// MARK: - Plan model

/// One field where multiple libraries hold DIFFERENT real values.
public struct ActorSyncConflict: Sendable, Equatable {
    public struct ValueSource: Sendable, Equatable {
        public let value: String
        /// The libraries holding this exact value, in precedence order.
        public let libraries: [URL]
    }

    public let field: ActorSyncField
    /// Distinct values in order of first appearance (precedence order).
    public let values: [ValueSource]

    public var supportsKeepBoth: Bool { field.isMultiValue }

    /// The "Keep Both" result: the union of every side's comma-separated
    /// entries, order of first appearance, deduped.
    public var keepBothValue: String {
        var seen: [String] = []
        for source in values {
            for entry in ActorSync.splitList(source.value) where !seen.contains(entry) {
                seen.append(entry)
            }
        }
        return seen.joined(separator: ", ")
    }
}

/// Everything that would change for one actor, across the open libraries.
public struct ActorSyncPlan: Sendable, Identifiable, Equatable {
    /// One line naming exactly why this actor is still listed.
    ///
    /// Exists because a non-converging sync reports nothing: no error, no
    /// failure, just the same names returning after every apply. Without this
    /// the only way to tell a photo gap from a field gap is to read the code
    /// and guess — which is how two wrong diagnoses got shipped.
    public func diagnosis(libraryNames: [URL: String] = [:]) -> String {
        func name(_ url: URL) -> String { libraryNames[url] ?? url.lastPathComponent }
        var parts: [String] = []
        if !deletionFrom.isEmpty {
            return "will be DELETED from [\(deletionFrom.map(name).joined(separator: ", "))]"
        }
        if !missingFrom.isEmpty {
            parts.append("missing from [\(missingFrom.map(name).joined(separator: ", "))]")
        }
        if !conflicts.isEmpty {
            parts.append("conflicts: \(conflicts.map { "\($0.field)" }.joined(separator: ","))")
        }
        for (url, n) in blankFills.sorted(by: { name($0.key) < name($1.key) }) where n > 0 {
            parts.append("\(name(url)) needs \(n) field fill\(n == 1 ? "" : "s")")
        }
        for (url, n) in listAdds.sorted(by: { name($0.key) < name($1.key) }) where n > 0 {
            parts.append("\(name(url)) needs \(n) tag/AKA add\(n == 1 ? "" : "s")")
        }
        for (url, n) in photoAdds.sorted(by: { name($0.key) < name($1.key) }) where n > 0 {
            parts.append("\(name(url)) needs \(n) photo\(n == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "no differences" : parts.joined(separator: "; ")
    }

    public var id: String { actorId }
    public let actorId: String
    public var displayName: String {
        actorId.hasPrefix("actor:") ? String(actorId.dropFirst(6)) : actorId
    }

    /// Libraries that don't have this actor at all (full record + photos copy).
    public let missingFrom: [URL]
    /// Libraries the actor will be REMOVED from, because some library recorded
    /// a deliberate deletion that outranks the copy they still hold.
    public var deletionFrom: [URL] = []
    /// Per existing library: how many blank/subset fields sync would fill.
    public let blankFills: [URL: Int]
    /// Per existing library: how many photos sync would add.
    public let photoAdds: [URL: Int]
    /// Per existing library: how many tag/AKA entries sync would add.
    public let listAdds: [URL: Int]
    /// Fields needing a user decision before this actor can fully converge.
    public let conflicts: [ActorSyncConflict]

    public var needsSync: Bool {
        !deletionFrom.isEmpty
            || !missingFrom.isEmpty || !conflicts.isEmpty
            || blankFills.values.contains { $0 > 0 }
            || photoAdds.values.contains { $0 > 0 }
            || listAdds.values.contains { $0 > 0 }
    }
}

/// The user's decision for one conflicted field.
public enum ActorSyncResolution: Sendable, Equatable {
    /// Set this exact value everywhere.
    case use(String)
    /// Multi-value fields only: union both sides' entries ("Brown, Red").
    case keepBoth
    /// Leave each library's own value untouched (the field stays diverged).
    case skip
}

// MARK: - Engine

public enum ActorSync {

    /// One open library's actor data, gathered once and reused for planning
    /// AND applying (the export carries photo bytes + content hashes).
    public struct LibrarySnapshot: Sendable {
        public let url: URL
        public let export: ActorLibraryExport

        public init(url: URL, export: ActorLibraryExport) {
            self.url = url
            self.export = export
        }
    }

    /// Gathers a snapshot from disk. Order of snapshots passed to `plan` is
    /// the precedence order (primary first).
    /// Everything about one actor that a plan compares, per library.
    ///
    /// Printed for actors that survive an apply. A stuck actor means some value
    /// differs that the merge is not writing, and the fastest way to find it is
    /// to see both sides side by side rather than to reason about the merge.
    public static func diagnosticDump(actorId: String, snapshots: [LibrarySnapshot]) -> String {
        var out = "  ── \(actorId)\n"
        for snap in snapshots {
            let label = snap.url.lastPathComponent
            guard let profile = snap.export.profiles.first(where: { $0.id == actorId }) else {
                out += "     [\(label)] ABSENT\n"
                continue
            }
            out += "     [\(label)] primary=\(profile.photoUrl ?? "nil")\n"
            out += "     [\(label)] gallery=\(profile.galleryUrls)\n"
            out += "     [\(label)] state=\(profile.enrichmentState?.rawValue ?? "nil")"
                + " checked=\(profile.enrichmentCheckedAt.map { "\($0.timeIntervalSince1970)" } ?? "nil")\n"
            out += "     [\(label)] tags=\(profile.tags.count) akas=\(profile.akas.count)"
                + " links=\(profile.links.count)\n"
            let photos = snap.export.photos.filter { $0.actorId == actorId }
            if photos.isEmpty {
                out += "     [\(label)] photos: none exported\n"
            }
            for photo in photos {
                out += "     [\(label)] photo hash=\(photo.contentHash.prefix(10))"
                    + " primary=\(photo.isPrimary) token=\(photo.sourceToken ?? "nil")\n"
            }
        }
        return out
    }

    /// Metadata plus photo HASHES — deliberately not photo bytes.
    ///
    /// Planning compares photos by content hash and never reads `data`. Loading
    /// the bytes made a snapshot cost as much as the library's entire photo
    /// store, and a plan holds one snapshot per library for as long as the
    /// screen is open.
    public static func snapshot(of libraryURL: URL) throws -> LibrarySnapshot {
        LibrarySnapshot(url: libraryURL,
                        export: try LibraryStore(at: libraryURL)
                            .exportGraph(includingPhotoData: false))
    }

    /// A snapshot carrying real photo bytes for a bounded set of actors.
    ///
    /// Used at apply time, one batch at a time, so peak memory follows the
    /// batch size rather than the size of the library.
    public static func photoBearingSnapshot(of libraryURL: URL,
                                            actorIds: Set<String>) throws -> LibrarySnapshot {
        LibrarySnapshot(url: libraryURL,
                        export: try LibraryStore(at: libraryURL)
                            .exportGraph(onlyActorIds: actorIds, includingPhotoData: true))
    }

    // MARK: Planning (pure)

    /// Plans the sync for every actor that differs across `snapshots`
    /// (precedence order). Actors already identical everywhere are omitted.
    public static func plan(for snapshots: [LibrarySnapshot]) -> [ActorSyncPlan] {
        guard snapshots.count > 1 else { return [] }

        let profilesByLibrary: [[String: EntityProfile]] = snapshots.map { snap in
            Dictionary(uniqueKeysWithValues: snap.export.profiles.map { ($0.id, $0) })
        }
        let hashesByLibrary: [[String: Set<String>]] = snapshots.map { snap in
            var byActor: [String: Set<String>] = [:]
            for photo in snap.export.photos {
                byActor[photo.actorId, default: []].insert(photo.contentHash)
            }
            return byActor
        }

        var allActorIds: [String] = []
        for profiles in profilesByLibrary {
            for id in profiles.keys where !allActorIds.contains(id) {
                allActorIds.append(id)
            }
        }

        // Newest deletion per entity across every library. A deletion recorded
        // anywhere is a fact about the entity, not about that one library.
        var newestTombstone: [String: EntityTombstone] = [:]
        for snap in snapshots {
            for stone in snap.export.tombstones {
                if let held = newestTombstone[stone.entityId], held.deletedAt >= stone.deletedAt { continue }
                newestTombstone[stone.entityId] = stone
            }
        }

        var plans: [ActorSyncPlan] = []
        for actorId in allActorIds {
            // (library index, profile) for libraries that have the actor.
            let holders: [(index: Int, profile: EntityProfile)] = profilesByLibrary.enumerated()
                .compactMap { index, profiles in profiles[actorId].map { (index, $0) } }
            let missingFrom = snapshots.indices
                .filter { index in !holders.contains { $0.index == index } }
                .map { snapshots[$0].url }

            // A recorded deletion supersedes copying: there is no point
            // reconciling fields on a record that is going away, and computing
            // "needs 1 photo" for it would be actively misleading.
            if let stone = newestTombstone[actorId] {
                let removeFrom = holders
                    .filter { TombstoneRules.shouldPropagate(tombstone: stone, to: $0.profile) }
                    .map { snapshots[$0.index].url }
                if !removeFrom.isEmpty {
                    plans.append(ActorSyncPlan(actorId: actorId,
                                               missingFrom: [],
                                               deletionFrom: removeFrom,
                                               blankFills: [:], photoAdds: [:],
                                               listAdds: [:], conflicts: []))
                    continue
                }
            }

            // Field classification across holders.
            var conflicts: [ActorSyncConflict] = []
            var fillsByIndex: [Int: Int] = [:]
            for field in ActorSyncField.allCases {
                let values = holders.map { (index: $0.index, value: field.value(in: $0.profile)) }
                let realValues = values.compactMap(\.value)
                guard !realValues.isEmpty else { continue }

                if field.isMultiValue {
                    // Sets: one side ⊆ another is a GAP (extend to the
                    // superset); genuinely different sets are a conflict.
                    let sets = values.map { (index: $0.index, set: Set(splitList($0.value ?? ""))) }
                    let unionSet = sets.reduce(into: Set<String>()) { $0.formUnion($1.set) }
                    let distinctNonEmpty = Set(sets.map(\.set).filter { !$0.isEmpty })
                    let hasConflict = distinctNonEmpty.count > 1
                        && !distinctNonEmpty.contains(unionSet)
                    if hasConflict {
                        conflicts.append(conflict(for: field, holders: holders, urls: snapshots.map(\.url)))
                    } else {
                        for entry in sets where entry.set != unionSet {
                            fillsByIndex[entry.index, default: 0] += 1
                        }
                    }
                } else {
                    let distinct = orderedDistinct(realValues)
                    if distinct.count > 1 {
                        conflicts.append(conflict(for: field, holders: holders, urls: snapshots.map(\.url)))
                    } else {
                        for entry in values where entry.value == nil {
                            fillsByIndex[entry.index, default: 0] += 1
                        }
                    }
                }
            }

            // Tag/AKA union adds per holder.
            var listAddsByIndex: [Int: Int] = [:]
            let tagsUnion = orderedUnion(holders.map { $0.profile.tags })
            let akasUnion = orderedUnion(holders.map { $0.profile.akas })
            for holder in holders {
                let adds = (tagsUnion.count - holder.profile.tags.count)
                    + (akasUnion.count - holder.profile.akas.count)
                if adds > 0 { listAddsByIndex[holder.index] = adds }
            }

            // Photo adds per holder (hashes present elsewhere, absent locally).
            var photoAddsByIndex: [Int: Int] = [:]
            let allHashes = holders.reduce(into: Set<String>()) {
                $0.formUnion(hashesByLibrary[$1.index][actorId] ?? [])
            }
            for holder in holders {
                let local = hashesByLibrary[holder.index][actorId] ?? []
                let adds = allHashes.subtracting(local).count
                if adds > 0 { photoAddsByIndex[holder.index] = adds }
            }

            let plan = ActorSyncPlan(
                actorId: actorId,
                missingFrom: missingFrom,
                blankFills: rekey(fillsByIndex, snapshots: snapshots),
                photoAdds: rekey(photoAddsByIndex, snapshots: snapshots),
                listAdds: rekey(listAddsByIndex, snapshots: snapshots),
                conflicts: conflicts)
            if plan.needsSync { plans.append(plan) }
        }

        return plans.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: Convergence (pure)

    /// Builds the merge SOURCE applied to every library: converged profiles
    /// for the selected actors (conflict resolutions honored; unresolved
    /// conflicts default to `.skip`, encoded as nil so each destination keeps
    /// its own value) plus the union photo payload, deduped by content hash
    /// with precedence order preserved.
    public static func convergedExport(
        actorIds: Set<String>,
        resolutions: [String: [ActorSyncField: ActorSyncResolution]],
        snapshots: [LibrarySnapshot]
    ) -> ActorLibraryExport {
        let profilesByLibrary: [[String: EntityProfile]] = snapshots.map { snap in
            Dictionary(uniqueKeysWithValues: snap.export.profiles.map { ($0.id, $0) })
        }

        var profiles: [EntityProfile] = []
        for actorId in actorIds.sorted() {
            let holders: [(index: Int, profile: EntityProfile)] = profilesByLibrary.enumerated()
                .compactMap { index, byId in byId[actorId].map { (index, $0) } }
            guard !holders.isEmpty else { continue }

            var converged = EntityProfile(
                id: actorId,
                tags: orderedUnion(holders.map { $0.profile.tags }),
                galleryUrls: orderedUnion(holders.map { $0.profile.galleryUrls }),
                akas: orderedUnion(holders.map { $0.profile.akas }),
                createdAt: holders.compactMap { $0.profile.createdAt }.min(),
                // enrichmentCheckedAt is set AFTER the field loop, once the
                // enrichment result is known — it has to agree with the state
                // it timestamps. See the note below.
                //
                // Not an ActorSyncField: a timestamp has no meaningful "keep
                // both", and asking a person to resolve one would be noise.
                // Links union like tags and AKAs rather than conflicting: two
                // libraries holding different links for one actor both hold
                // true facts, and the union is what the user wants.
                links: holders.reduce(into: [EntityLink]()) { union, holder in
                    union = EntityLink.merged(union, adding: holder.profile.links)
                })

            let conflictFields = Set(conflictedFields(holders: holders))
            for field in ActorSyncField.allCases {
                if conflictFields.contains(field) {
                    switch resolutions[actorId]?[field] ?? .skip {
                    case .use(let value):
                        field.apply(value, to: &converged)
                    case .keepBoth:
                        field.apply(conflict(for: field, holders: holders, urls: snapshots.map(\.url)).keepBothValue,
                                    to: &converged)
                    case .skip:
                        field.apply(nil, to: &converged)
                    }
                } else if field.isMultiValue {
                    let unionEntries = orderedUnion(holders.map { splitList(field.value(in: $0.profile) ?? "") })
                    field.apply(unionEntries.isEmpty ? nil : unionEntries.joined(separator: ", "),
                                to: &converged)
                } else {
                    // Non-conflicted scalar: at most one distinct real value.
                    field.apply(holders.compactMap { field.value(in: $0.profile) }.first,
                                to: &converged)
                }
            }

            // The check timestamp must travel WITH the enrichment result it
            // describes, never independently.
            //
            // `MergeSemantics.newerChecked` treats this timestamp as authority
            // over the whole enrichment triple: the side holding the newer one
            // supplies state, source AND timestamp wholesale. A converged
            // profile carrying the newest timestamp but a nil state — which is
            // what a skipped conflict produces — therefore ERASES a populated
            // result in every destination, and the next plan sees the same gap
            // and does it again. That is a sync that never converges.
            //
            // So: no result, no timestamp. With a result, take the most recent
            // check that actually produced that result.
            // Travels with the result it identifies, same as the timestamp.
            converged.enrichmentSourceId = holders
                .compactMap { $0.profile.enrichmentSourceId }.first
            converged.enrichmentCheckedAt = converged.enrichmentState.flatMap { state in
                holders
                    .filter { $0.profile.enrichmentState == state }
                    .compactMap { $0.profile.enrichmentCheckedAt }
                    .max()
            }

            profiles.append(converged)
        }

        // Union photo payload: first occurrence (precedence order) wins the
        // token/primary flag for each distinct content hash.
        var seenHashes = Set<String>()
        var photos: [ExportedPhoto] = []
        for snapshot in snapshots {
            for photo in snapshot.export.photos
            where actorIds.contains(photo.actorId) && !seenHashes.contains("\(photo.actorId)|\(photo.contentHash)") {
                seenHashes.insert("\(photo.actorId)|\(photo.contentHash)")
                photos.append(photo)
            }
        }

        // Every library's deletions travel with the converged record. Without
        // this the plan can SHOW a deletion but applying would never perform it.
        var tombstones: [String: EntityTombstone] = [:]
        for snap in snapshots {
            for stone in snap.export.tombstones {
                if let held = tombstones[stone.entityId], held.deletedAt >= stone.deletedAt { continue }
                tombstones[stone.entityId] = stone
            }
        }

        var export = ActorLibraryExport(formatVersion: ActorLibraryExport.currentFormatVersion,
                                        exportedAt: Date(), profiles: profiles, photos: photos,
                                        tombstones: Array(tombstones.values))

        // The rest of the graph, unioned across every library so applying this
        // to each of them leaves them all holding the same thing.
        //
        // ⚠️ No per-field conflict resolution here, unlike actors. A studio or
        // a tag has one fact worth carrying — is it confirmed, what kind is it
        // — and `applyGraphMerge` is additive: it fills gaps and upgrades
        // unknowns, and never overwrites a decision the receiving library has
        // already made. So a genuine disagreement (A says action, B says
        // video-attribute) leaves BOTH untouched rather than one silently
        // winning. That is a gap in what the operator gets asked about, not a
        // gap in what is protected.
        export.studios = preferring(snapshots.flatMap(\.export.studios), by: \.id) { new, held in
            held.enrichmentState == .matched ? held : new
        }
        export.tags = preferring(snapshots.flatMap(\.export.tags), by: \.identityKey) { new, held in
            held.kind != nil ? held : new
        }
        export.performerTags = orderedDistinctEdges(snapshots.flatMap(\.export.performerTags))
        export.studioParents = orderedDistinctEdges(snapshots.flatMap(\.export.studioParents))
        return export
    }

    /// First occurrence wins unless `resolve` says the later one is better.
    private static func preferring<T, K: Hashable>(
        _ values: [T], by key: (T) -> K, resolve: (T, T) -> T
    ) -> [T] {
        var byKey: [K: T] = [:]
        var order: [K] = []
        for value in values {
            let k = key(value)
            if let held = byKey[k] {
                byKey[k] = resolve(value, held)
            } else {
                byKey[k] = value
                order.append(k)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private static func orderedDistinctEdges<E: Hashable>(_ edges: [E]) -> [E] {
        var seen = Set<E>()
        return edges.filter { seen.insert($0).inserted }
    }

    /// Applies the converged export to one library — the existing merge
    /// engine does the heavy lifting (field semantics, photo dedupe/adoption,
    /// single transaction).
    @discardableResult
    public static func apply(_ export: ActorLibraryExport, to libraryURL: URL) throws -> GraphMergeResult {
        // ⚠️ The whole graph, not just the actors. The live sync converges two
        // attached libraries; leaving studios, the tag vocabulary and the
        // portable edges out meant the file-based route carried them and this
        // one silently did not — two ways to sync that produced different
        // libraries.
        try LibraryStore(at: libraryURL).applyGraphMerge(export)
    }

    // MARK: - Helpers

    /// Splits a comma-separated multi-value string into trimmed entries.
    static func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func orderedDistinct(_ values: [String]) -> [String] {
        var seen: [String] = []
        for value in values where !seen.contains(value) { seen.append(value) }
        return seen
    }

    private static func orderedUnion(_ lists: [[String]]) -> [String] {
        var seen: [String] = []
        for list in lists {
            for item in list where !seen.contains(item) { seen.append(item) }
        }
        return seen
    }

    private static func rekey(_ byIndex: [Int: Int], snapshots: [LibrarySnapshot]) -> [URL: Int] {
        Dictionary(uniqueKeysWithValues: byIndex.map { (snapshots[$0.key].url, $0.value) })
    }

    private static func conflictedFields(holders: [(index: Int, profile: EntityProfile)]) -> [ActorSyncField] {
        ActorSyncField.allCases.filter { field in
            if field.isMultiValue {
                let sets = holders.map { Set(splitList(field.value(in: $0.profile) ?? "")) }
                let unionSet = sets.reduce(into: Set<String>()) { $0.formUnion($1) }
                let distinctNonEmpty = Set(sets.filter { !$0.isEmpty })
                return distinctNonEmpty.count > 1 && !distinctNonEmpty.contains(unionSet)
            } else {
                let distinct = orderedDistinct(holders.compactMap { field.value(in: $0.profile) })
                return distinct.count > 1
            }
        }
    }

    private static func conflict(
        for field: ActorSyncField,
        holders: [(index: Int, profile: EntityProfile)],
        urls: [URL]
    ) -> ActorSyncConflict {
        // Group holders by their exact value, order of first appearance.
        var order: [String] = []
        var byValue: [String: [Int]] = [:]
        for holder in holders {
            guard let value = field.value(in: holder.profile) else { continue }
            if byValue[value] == nil { order.append(value) }
            byValue[value, default: []].append(holder.index)
        }
        return ActorSyncConflict(field: field, values: order.map { value in
            ActorSyncConflict.ValueSource(value: value, libraries: byValue[value]!.map { urls[$0] })
        })
    }
}
