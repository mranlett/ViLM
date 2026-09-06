// LibrarySession.swift
// The open-library set and the per-asset SOURCE RESOLVER — the foundation of
// the multi-library session feature (plans/dual-library-session.md).
//
// Today the app assumes one `libraryURL` everywhere. This object replaces that
// assumption with a question that stays answerable when several libraries are
// open at once: "which library owns this asset?" Every per-asset file path
// (video, thumbnail, contact sheet, marker preview) and every per-asset store
// write must resolve through here; library-GLOBAL operations (profile loads,
// scans, backup, collection CRUD) keep using the explicit library URL they're
// operating on.
//
// Phase 1 contract (current): `attachedURLs` is always empty and
// `sourceByAsset` is never populated, so `url(for:)` always answers the
// primary — the resolver is the identity function and behavior is EXACTLY the
// single-library app. Later phases populate attachments and the source map;
// no resolver call site should need to change again.
//
// A shared singleton (the QuickActionRouter precedent) rather than an
// EnvironmentObject: ~30 files resolve through it, and a missed environment
// injection is a runtime crash while a missed singleton reference is a
// compile error.

import Foundation
import Combine
import LibraryCore

@MainActor
final class LibrarySession: ObservableObject {
    static let shared = LibrarySession()

    /// The main library (persisted across launches via ContentView's bookmark).
    @Published private(set) var primaryURL: URL?
    /// Session-only attachments in attach order — which IS the precedence
    /// order for merged-view conflicts and id collisions. Never persisted:
    /// a relaunch reopens the primary alone by construction.
    @Published private(set) var attachedURLs: [URL] = []

    /// Owning library per asset, rebuilt on every union (re)load. Assets not
    /// in the map belong to the primary (always true in single-library mode).
    private var sourceByAsset: [Asset.ID: URL] = [:]

    /// Attachments whose security-scope claim succeeded (folder-picker URLs
    /// need one; already-accessible paths decline harmlessly). The claim is
    /// owned by the SESSION and released only on detach — never by a view.
    private var scopedAttachments: Set<URL> = []

    /// Libraries whose studios have already been given profiles this session.
    ///
    /// Session-scoped rather than persisted: promotion is idempotent and cheap
    /// once, and a fresh launch re-checking is exactly the behaviour wanted.
    private var studiosPromoted: Set<URL> = []

    /// Claims the promotion for `url`, returning true only for the first caller.
    ///
    /// Returns a decision rather than exposing the set, so the check and the
    /// claim cannot drift apart — two reloads racing would otherwise both read
    /// "not yet" and both run.
    @discardableResult
    func markStudiosPromoted(_ url: URL) -> Bool {
        studiosPromoted.insert(url).inserted
    }

    private init() {}

    var isFederated: Bool { !attachedURLs.isEmpty }

    /// Every open library, primary first, then attachments in precedence order.
    ///
    /// ⚠️ DE-DUPLICATED, order preserved. If a library were ever both primary
    /// and attached, every caller that walks this list would visit it twice —
    /// the batch matcher would scan each of its videos a second time, the
    /// filename reader would double-count, and totals would read double the
    /// library. Guarding at attach time is not enough: `setPrimary` does not
    /// check whether its new primary is already an attachment, and a caller
    /// cannot be expected to know that.
    var allURLs: [URL] {
        var seen = Set<URL>()
        return ((primaryURL.map { [$0] } ?? []) + attachedURLs)
            .filter { seen.insert($0).inserted }
    }

    /// Called from every path that opens/switches the active library.
    /// Idempotent; switching primaries ends the session — every attachment
    /// is detached (scopes released, connections dropped) because attachments
    /// belong to a session, not to the app.
    func setPrimary(_ url: URL?) {
        guard primaryURL != url else {
            // Same primary, but it may ALSO be sitting in the attachment list
            // — opening a library that was already attached would otherwise
            // leave it open twice, and every list-walking caller would process
            // it twice.
            if let url, attachedURLs.contains(url) { detach(url) }
            return
        }
        for attached in attachedURLs.reversed() {
            detach(attached)
        }
        primaryURL = url
        sourceByAsset = [:]
        profilePresence = [:]
    }

    // MARK: - Attach / detach (session-scoped, never persisted)

    /// Opens `url` as an attachment at the END of the precedence order.
    /// Claims security-scoped access on the picked URL; the claim lives until
    /// `detach`. Caller validates first (has a `.catalog`, not already open).
    func attach(_ url: URL) {
        guard primaryURL != nil, !allURLs.contains(url) else { return }
        if url.startAccessingSecurityScopedResource() {
            scopedAttachments.insert(url)
        }
        attachedURLs.append(url)
    }

    /// Closes one attachment: releases its scope claim, drops its cached
    /// database connection (targeted — other open libraries are untouched),
    /// and forgets its assets' source mappings.
    func detach(_ url: URL) {
        guard let index = attachedURLs.firstIndex(of: url) else { return }
        attachedURLs.remove(at: index)
        // Detaching ends this library's session, so a later re-attach must be
        // able to promote again — studios may have been added while it was away.
        studiosPromoted.remove(url)
        if scopedAttachments.remove(url) != nil {
            url.stopAccessingSecurityScopedResource()
        }
        LibraryStore.evictCachedConnection(forLibraryAt: url)
        sourceByAsset = sourceByAsset.filter { $0.value != url }
        profilePresence = profilePresence.compactMapValues { urls in
            let remaining = urls.filter { $0 != url }
            return remaining.isEmpty ? nil : remaining
        }
    }

    // MARK: - Union loading

    struct UnionLoad {
        let assets: [Asset]
        /// Rows hidden because an open library already had the identical id
        /// (backup-cloned libraries), per attachment that had any.
        let excludedCloneCounts: [URL: Int]
    }

    /// Fetches the session's asset union — primary first, then each
    /// attachment in precedence order, id collisions hidden (first occurrence
    /// wins) — and rebuilds the source map in the same pass. THE one way any
    /// reload path should fetch assets: with no attachments it degenerates to
    /// exactly the old single-library fetch.
    func fetchUnionAssets() throws -> UnionLoad {
        guard let primaryURL else { return UnionLoad(assets: [], excludedCloneCounts: [:]) }
        var union = try LibraryStore(at: primaryURL).fetchAllAssets()
        var ids = Set(union.map(\.id))
        var excluded: [URL: Int] = [:]
        var newMap: [Asset.ID: URL] = [:]
        for url in attachedURLs {
            let rows = try LibraryStore(at: url).fetchAllAssets()
            let partition = LibraryFederation.partitionForUnion(incoming: rows, existingIDs: ids)
            for asset in partition.included {
                newMap[asset.id] = url
                ids.insert(asset.id)
            }
            if !partition.excludedIDs.isEmpty {
                excluded[url] = partition.excludedIDs.count
            }
            union.append(contentsOf: partition.included)
        }
        sourceByAsset = newMap
        return UnionLoad(assets: union, excludedCloneCounts: excluded)
    }

    // MARK: - Resolution (the whole point)

    /// The library that owns `assetID` — the primary unless a union load
    /// mapped the asset to an attachment.
    func url(for assetID: Asset.ID) -> URL? {
        sourceByAsset[assetID] ?? primaryURL
    }

    /// The asset's video file, under its owning library.
    func videoURL(for asset: Asset) -> URL? {
        url(for: asset.id)?.appendingPathComponent(asset.relativePath)
    }

    /// A store on the asset's owning library.
    func store(for assetID: Asset.ID) throws -> LibraryStore {
        guard let url = url(for: assetID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try LibraryStore(at: url)
    }

    // MARK: - Display names (path-based, unique within the open set)

    /// Compact chip label for one open library — shortest path suffix unique
    /// within the open set ("Videos", or "PortableSSD/…/Videos" on collision).
    func shortLabel(for url: URL) -> String {
        LibraryDisplayName.labels(for: allURLs)[url]?.short ?? url.lastPathComponent
    }

    /// Prettified full path ("~/Downloads/Videos") — sidebar rows, notes,
    /// tooltips.
    func fullLabel(for url: URL) -> String {
        LibraryDisplayName.labels(for: allURLs)[url]?.full ?? url.path
    }

    // MARK: - Entity profiles (merged actor view)

    /// Which open libraries contain each entity profile, in precedence order —
    /// rebuilt with every profile load. Head of the list = the profile's
    /// owning library: the one edits and photo downloads write to.
    private var profilePresence: [String: [URL]] = [:]

    func setProfilePresence(_ map: [String: [URL]]) {
        profilePresence = map
    }

    /// Every library holding this profile, in precedence order.
    ///
    /// 🚨 Tries the id first, then the node's IDENTITY. Callers reach these
    /// methods with a name-form id they built themselves (`"actor:\(name)"`),
    /// and after the re-key that matches no uid — so an id-only lookup would
    /// miss every time, `url(forProfile:)` would fall back to the primary
    /// library, and an attachment's profile would be written into the wrong
    /// catalogue with nothing reporting it.
    ///
    /// ⚠️ Both forms are recorded by `ContentView.loadEntityProfiles`, so this
    /// resolves whether it is handed a uid or a legacy name-form id.
    private func libraries(holdingProfile id: String) -> [URL] {
        if let direct = profilePresence[id] { return direct }
        if let identity = NodeIdentity.parse(id),
           let byIdentity = profilePresence[identity.resolutionKey] {
            return byIdentity
        }
        return []
    }

    /// The library that owns writes for this profile: the highest-precedence
    /// open library that has it, or the primary for a brand-new profile.
    func url(forProfile id: String) -> URL? {
        libraries(holdingProfile: id).first ?? primaryURL
    }

    func store(forProfile id: String) throws -> LibraryStore {
        guard let url = url(forProfile: id) else { throw CocoaError(.fileNoSuchFile) }
        return try LibraryStore(at: url)
    }

    /// Open libraries (beyond the owner) that also contain this profile —
    /// what the editor's "edits apply to …" note is based on.
    func otherLibraries(containingProfile id: String) -> [URL] {
        Array(libraries(holdingProfile: id).dropFirst())
    }

    /// Every open library's profile-photo directory, in precedence order.
    var profilesDirs: [URL] {
        allURLs.map { $0.appendingPathComponent(".catalog/profiles") }
    }

    /// The first open library that has `fileName` cached on disk (display
    /// lookup — precedence order). Nil when no open library has it.
    func existingProfilePhotoURL(fileName: String) -> URL? {
        for dir in profilesDirs {
            let candidate = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Where a NEW photo file for this profile should be written: the owning
    /// library's profiles directory.
    func profilesDir(forProfile id: String) -> URL? {
        url(forProfile: id)?.appendingPathComponent(".catalog/profiles")
    }

    // MARK: - Profile thumbnail derivatives (#84)
    //
    // A grid cell must not decode a 4–5 MB source JPEG to draw itself. These
    // mirror the profiles accessors exactly, one directory across, because the
    // lookup rules are the same: read from any open library in precedence
    // order, write to the owning one.

    /// Every open library's profile-derivative directory, in precedence order.
    var profileThumbsDirs: [URL] {
        allURLs.map { $0.appendingPathComponent(ProfileThumbnailNaming.relativePath) }
    }

    /// The first open library holding this derivative. Nil when none does.
    ///
    /// ⚠️ Presence only — the caller MUST still check freshness against the
    /// source's modification date via `ProfileThumbnailNaming.isFresh`. The
    /// primary photo's filename is fixed per entity, so "the file is there" is
    /// not "the file is current"; that conflation is #21 exactly.
    func existingProfileThumbnailURL(fileName: String) -> URL? {
        for dir in profileThumbsDirs {
            let candidate = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Where a NEW derivative for this profile should be written: the owning
    /// library's derivative directory.
    func profileThumbsDir(forProfile id: String) -> URL? {
        url(forProfile: id)?.appendingPathComponent(ProfileThumbnailNaming.relativePath)
    }

    // MARK: - Per-asset catalog artifacts

    func thumbnailURL(for assetID: Asset.ID) -> URL? {
        url(for: assetID)?.appendingPathComponent(".catalog/thumbnails/\(assetID.uuidString).jpg")
    }

    func contactSheetURL(for assetID: Asset.ID) -> URL? {
        url(for: assetID)?.appendingPathComponent(".catalog/contactSheets/\(assetID.uuidString).jpg")
    }

    /// A scene marker's preview image lives in the library that owns the
    /// marker's ASSET (markers have no independent home).
    func markerThumbnailURL(markerId: UUID, ownerAssetID: Asset.ID) -> URL? {
        url(for: ownerAssetID)?.appendingPathComponent(".catalog/markers/\(markerId.uuidString).jpg")
    }
}
