// RelocationPlan.swift
// What a rename WOULD do, computed whole and shown before anything moves (#17).
//
// 🚨 The plan is the safety property, not a preview. Renaming in place across
// two thousand files has no copy to fall back on, so the difference between a
// feature and a way to lose a library is whether every step is known before the
// first one runs.
//
// ⭐ Reads nothing it does not need and writes NOTHING AT ALL — F3. A dry run
// that touches the filesystem is not a dry run, and the assertion for that is
// worth more than the code.
//
// ⚠️ Collisions are found HERE, before the run, not discovered mid-way. Two
// videos resolving to one path is ordinary — a studio with two undated scenes
// and the same cast produces it — and the answer is to report the pair, never
// to let one silently overwrite the other.

import Foundation
import GRDB

/// One file that would move.
public struct PlannedMove: Equatable, Sendable, Identifiable {
    public let assetId: UUID
    public let from: String
    public let to: String
    /// What to call it in the report.
    public let title: String

    public var id: UUID { assetId }
}

/// One file that cannot be filed, and why.
public struct UnfilableVideo: Equatable, Sendable, Identifiable {
    public let assetId: UUID
    public let path: String
    public let title: String
    public let skip: NamingSkip

    public var id: UUID { assetId }
}

/// Two or more files that want the same path.
public struct PathCollision: Equatable, Sendable, Identifiable {
    public let target: String
    public let assetIds: [UUID]
    public let titles: [String]

    public var id: String { target }
}

public struct RelocationPlan: Equatable, Sendable {
    public let moves: [PlannedMove]
    /// Already where they belong. Counted, so "nothing to do" is
    /// distinguishable from "nothing was examined".
    public let alreadyInPlace: Int
    public let unfilable: [UnfilableVideo]
    public let collisions: [PathCollision]

    public var isEmpty: Bool { moves.isEmpty && collisions.isEmpty }

    /// ⚠️ A plan with collisions must not run. Reported as a property rather
    /// than left for each caller to remember.
    public var canRun: Bool { collisions.isEmpty && !moves.isEmpty }

    /// Why each unfilable video was skipped, counted by reason — the shape the
    /// operator actually needs, since "90 need an episode number" is a work
    /// list and ninety separate rows is not.
    public var unfilableByReason: [(reason: String, count: Int)] {
        Dictionary(grouping: unfilable, by: { $0.skip.reason })
            .map { (reason: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
    }

    public func headline() -> String {
        var parts = ["\(moves.count) to move"]
        if alreadyInPlace > 0 { parts.append("\(alreadyInPlace) already in place") }
        if !unfilable.isEmpty { parts.append("\(unfilable.count) cannot be filed yet") }
        if !collisions.isEmpty { parts.append("⚠️ \(collisions.count) collisions") }
        return parts.joined(separator: " · ")
    }
}

public extension LibraryStore {

    /// The whole plan, computed without touching the filesystem.
    func relocationPlan(personalFolder: String = "Personal",
                        unfiledFolder: String = "Unfiled") throws -> RelocationPlan {
        let assets = try fetchAllAssets()
        let profiles = try fetchAllEntityProfiles()
        var byId: [String: EntityProfile] = [:]
        for p in profiles { byId[p.id] = p }
        let resolver = NodeResolver(profiles: profiles)

        // ⚠️ Edges AND tag strings. Edges are the truth once Connect the Graph
        // has run, but a video the graph has not reached still carries its cast
        // as `actor:Name`, and filing it from an empty cast would be wrong
        // rather than merely incomplete.
        let (castByVideo, studioByVideo) = try edgeMemberships()

        var moves: [PlannedMove] = []
        var unfilable: [UnfilableVideo] = []
        var inPlace = 0
        var byTarget: [String: [(UUID, String)]] = [:]

        for asset in assets {
            let title = ActorKnownFor.displayTitle(asset)
            let context = NamingContext(
                studio: placement(for: asset, edges: studioByVideo, byId: byId, resolver: resolver),
                performers: cast(for: asset, edges: castByVideo, byId: byId, resolver: resolver),
                personalFolder: personalFolder,
                unfiledFolder: unfiledFolder)

            switch ContentNaming.path(for: asset, in: context) {
            case let .skipped(skip):
                unfilable.append(.init(assetId: asset.id, path: asset.relativePath,
                                       title: title, skip: skip))
            case let .path(target):
                guard target != asset.relativePath else { inPlace += 1; continue }
                moves.append(.init(assetId: asset.id, from: asset.relativePath,
                                   to: target, title: title))
                byTarget[target, default: []].append((asset.id, title))
            }
        }

        let collisions = byTarget
            .filter { $0.value.count > 1 }
            .map { PathCollision(target: $0.key,
                                 assetIds: $0.value.map(\.0),
                                 titles: $0.value.map(\.1)) }
            .sorted { $0.target < $1.target }

        return RelocationPlan(
            moves: moves.sorted { $0.to < $1.to },
            alreadyInPlace: inPlace,
            unfilable: unfilable.sorted { $0.path < $1.path },
            collisions: collisions)
    }

    // MARK: - Resolving what the grammar needs

    /// N1 — a studio earns a folder only by being matched to a source id.
    private func placement(for asset: Asset, edges: [UUID: String],
                           byId: [String: EntityProfile],
                           resolver: NodeResolver) -> StudioPlacement {
        let profile: EntityProfile? = {
            if let id = edges[asset.id], let p = byId[id] { return p }
            guard let name = asset.studios.first,
                  let id = resolver.localId(for: "studio:\(name)") else { return nil }
            return byId[id]
        }()
        guard let profile else { return .unprocessed }
        switch profile.enrichmentState {
        case .matched:      return .filed(profile.name)
        case .unmatchable:  return .unfiled
        // ⭐ Everything else is "not yet processed", and the file stays in the
        // root. A location states a processing status, so a studio still being
        // worked on must not look settled.
        default:            return .unprocessed
        }
    }

    private func cast(for asset: Asset, edges: [UUID: Set<String>],
                      byId: [String: EntityProfile],
                      resolver: NodeResolver) -> [PerformerRef] {
        var ids = edges[asset.id] ?? []
        for name in asset.actors {
            if let id = resolver.localId(for: "actor:\(name)") { ids.insert(id) }
        }
        return ids.compactMap { byId[$0] }
            .map { PerformerRef(name: $0.name, gender: $0.gender) }
    }

    /// Both edge tables in one pass.
    private func edgeMemberships() throws -> ([UUID: Set<String>], [UUID: String]) {
        try dbQueue.read { db in
            var cast: [UUID: Set<String>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT video_id, performer_id FROM video_performer") {
                guard let raw: String = row["video_id"], let id = UUID(uuidString: raw),
                      let performer: String = row["performer_id"] else { continue }
                cast[id, default: []].insert(performer)
            }
            var studio: [UUID: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT video_id, studio_id FROM video_studio") {
                guard let raw: String = row["video_id"], let id = UUID(uuidString: raw),
                      let studioId: String = row["studio_id"] else { continue }
                studio[id] = studioId
            }
            return (cast, studio)
        }
    }
}
