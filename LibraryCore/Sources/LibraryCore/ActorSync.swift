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
// Sync is additive and convergent only: deletions never propagate.
// See plans/actor-sync.md.

import Foundation

// MARK: - Fields

/// The scalar profile fields sync reasons about (tags/AKAs/galleries always
/// union and never conflict).
public enum ActorSyncField: String, CaseIterable, Sendable {
    case bio, homePage, gender, hairColor, birthYear, countryOfOrigin, rating
    // Career span (v17). Without these, syncing two libraries would leave
    // career data behind in whichever one happened to have it.
    case birthDate, careerSpanRaw, careerStartYear, careerEndYear, ageAtCareerStart

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
        case .birthYear: return "Birth Year"
        case .countryOfOrigin: return "Country"
        case .rating: return "Rating"
        case .birthDate: return "Birth Date"
        case .careerSpanRaw: return "Career Span (source text)"
        case .careerStartYear: return "Career Start"
        case .careerEndYear: return "Career End"
        case .ageAtCareerStart: return "Age at Career Start"
        }
    }

    func value(in profile: EntityProfile) -> String? {
        let raw: String?
        switch self {
        case .bio: raw = profile.bio
        case .homePage: raw = profile.homePage
        case .gender: raw = profile.gender
        case .hairColor: raw = profile.hairColor
        case .birthYear: raw = profile.birthYear.map(String.init)
        case .countryOfOrigin: raw = profile.countryOfOrigin
        case .rating: raw = profile.rating.map(String.init)
        case .birthDate: raw = profile.birthDate
        case .careerSpanRaw: raw = profile.careerSpanRaw
        case .careerStartYear: raw = profile.careerStartYear.map(String.init)
        case .careerEndYear: raw = profile.careerEndYear.map(String.init)
        case .ageAtCareerStart: raw = profile.ageAtCareerStart.map(String.init)
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
        case .birthYear: profile.birthYear = value.flatMap(Int.init)
        case .countryOfOrigin: profile.countryOfOrigin = value
        case .rating: profile.rating = value.flatMap(Int.init)
        case .birthDate: profile.birthDate = value
        case .careerSpanRaw: profile.careerSpanRaw = value
        case .careerStartYear: profile.careerStartYear = value.flatMap(Int.init)
        case .careerEndYear: profile.careerEndYear = value.flatMap(Int.init)
        case .ageAtCareerStart: profile.ageAtCareerStart = value.flatMap(Int.init)
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
    public var id: String { actorId }
    public let actorId: String
    public var displayName: String {
        actorId.hasPrefix("actor:") ? String(actorId.dropFirst(6)) : actorId
    }

    /// Libraries that don't have this actor at all (full record + photos copy).
    public let missingFrom: [URL]
    /// Per existing library: how many blank/subset fields sync would fill.
    public let blankFills: [URL: Int]
    /// Per existing library: how many photos sync would add.
    public let photoAdds: [URL: Int]
    /// Per existing library: how many tag/AKA entries sync would add.
    public let listAdds: [URL: Int]
    /// Fields needing a user decision before this actor can fully converge.
    public let conflicts: [ActorSyncConflict]

    public var needsSync: Bool {
        !missingFrom.isEmpty || !conflicts.isEmpty
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
    public static func snapshot(of libraryURL: URL) throws -> LibrarySnapshot {
        LibrarySnapshot(url: libraryURL,
                        export: try LibraryStore(at: libraryURL).exportActorLibrary())
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

        var plans: [ActorSyncPlan] = []
        for actorId in allActorIds {
            // (library index, profile) for libraries that have the actor.
            let holders: [(index: Int, profile: EntityProfile)] = profilesByLibrary.enumerated()
                .compactMap { index, profiles in profiles[actorId].map { (index, $0) } }
            let missingFrom = snapshots.indices
                .filter { index in !holders.contains { $0.index == index } }
                .map { snapshots[$0].url }

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
                createdAt: holders.compactMap { $0.profile.createdAt }.min())

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

        return ActorLibraryExport(formatVersion: ActorLibraryExport.currentFormatVersion, exportedAt: Date(), profiles: profiles, photos: photos)
    }

    /// Applies the converged export to one library — the existing merge
    /// engine does the heavy lifting (field semantics, photo dedupe/adoption,
    /// single transaction).
    @discardableResult
    public static func apply(_ export: ActorLibraryExport, to libraryURL: URL) throws -> ActorMergeResult {
        try LibraryStore(at: libraryURL).applyActorMerge(export)
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
