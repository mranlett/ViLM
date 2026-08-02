// DuplicateDetectionView.swift
// Settings tool: finds duplicate videos in the open library in two tiers —
// exact copies (same byte size + duration) and *visual matches* (same content
// in a different encode: near-identical duration confirmed by perceptual
// frame hashes, via VideoDuplicateAnalyzer). Each copy shows size, resolution,
// bitrate, and duration with "Largest" / "Highest res" badges so it's obvious
// at a glance which file is worth keeping. Deletion goes through
// VideoTransferService.deleteVideoAndArtifacts (file-first ordering, Trash,
// full artifact cleanup).

import SwiftUI
import LibraryCore
import AVFoundation

struct DuplicateDetectionView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let assets: [Asset]
    let onRefresh: () -> Void

    // nonisolated: compared inside the detached scan work; the synthesized
    // Equatable must not be MainActor-bound (a Swift 6 error otherwise).
    nonisolated enum Confidence {
        case exactCopy      // byte-identical size + duration
        case visualMatch    // different encode, same content, same length
        case overlapMatch   // same content, different length (trimmed copy)
    }

    struct FileMeta: Sendable {
        var sizeBytes: Int64 = 0
        var durationSeconds: Double?
        var modified: TimeInterval = 0
        var width: Int = 0
        var height: Int = 0
        var bitrateMbps: Double?
    }

    struct DuplicateGroup: Identifiable {
        let id = UUID()
        let confidence: Confidence
        var items: [Asset]
        /// For overlap groups: where the shorter copy's content starts in the
        /// longer one (e.g. "matches from 0:30 in the longer file").
        var note: String?
    }

    @State private var groups: [DuplicateGroup] = []
    @State private var meta: [Asset.ID: FileMeta] = [:]
    @State private var isScanning = true
    @State private var scanProgress = ""
    @State private var selectedForRemoval: Set<Asset.ID> = []
    @State private var isDeleting = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String? = nil

    private var duplicateCount: Int {
        groups.reduce(0) { $0 + max(0, $1.items.count - 1) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Duplicate Videos")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Delete Selected (\(selectedForRemoval.count))") {
                            showDeleteConfirm = true
                        }
                        .disabled(selectedForRemoval.isEmpty || isDeleting)
                    }
                }
                .overlay {
                    if isDeleting {
                        ProgressView("Deleting…")
                            .padding()
                            .background(.regularMaterial)
                            .cornerRadius(10)
                    }
                }
                .alert("Delete Files?", isPresented: $showDeleteConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) {
                        Task { await deleteSelected() }
                    }
                } message: {
                    Text("This moves \(selectedForRemoval.count) video file(s) to the Trash and removes them from the library.")
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(errorMessage ?? "")
                }
                .task { await scan() }
        }
        // Size the window on macOS only — on iPhone a fixed minWidth forces
        // the sheet wider than the screen, clipping content and the toolbar
        // buttons (same class as the move-page overflow fix).
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: 10) {
                ProgressView(scanProgress.isEmpty ? "Scanning for duplicates…" : scanProgress)
                Text("Exact copies are matched by size; look-alike encodes are confirmed by comparing sampled frames, which can take a moment.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            ContentUnavailableView(
                "No Duplicates Found",
                systemImage: "checkmark.seal",
                description: Text("No videos are byte-identical or visually match another video of the same length.")
            )
        } else {
            List {
                Section {
                    Text("Found \(duplicateCount) likely duplicate\(duplicateCount == 1 ? "" : "s") across \(groups.count) group\(groups.count == 1 ? "" : "s"). Select the copies to delete — keep at least one in each group.")
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                ForEach(groups) { group in
                    Section(header: groupHeader(group)) {
                        ForEach(group.items) { asset in
                            row(for: asset, in: group)
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack(spacing: 6) {
            switch group.confidence {
            case .exactCopy:
                Label("Exact copies", systemImage: "equal.circle.fill")
                    .foregroundColor(.green)
            case .visualMatch:
                Label("Same content, different quality", systemImage: "sparkles.rectangle.stack")
                    .foregroundColor(.orange)
            case .overlapMatch:
                Label("Overlapping content (trimmed?)", systemImage: "scissors")
                    .foregroundColor(.purple)
            }
            if let note = group.note {
                Text("· \(note)")
            } else if let duration = group.items.first.flatMap({ meta[$0.id]?.durationSeconds }) {
                Text("· \(Self.durationString(duration))")
            }
            Spacer()
            Text("\(group.items.count) copies")
        }
        .font(.caption)
    }

    private func row(for asset: Asset, in group: DuplicateGroup) -> some View {
        let m = meta[asset.id] ?? FileMeta()
        let isLargest = group.items.count > 1
            && m.sizeBytes == group.items.compactMap({ meta[$0.id]?.sizeBytes }).max()
        let isHighestRes = group.items.count > 1 && m.width * m.height > 0
            && m.width * m.height == group.items.compactMap({ meta[$0.id].map { $0.width * $0.height } }).max()

        return HStack(spacing: 12) {
            Image(systemName: selectedForRemoval.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selectedForRemoval.contains(asset.id) ? .red : .secondary)

            // Visual confirmation before deleting: each copy's own poster
            // (resolved from its owning library's cache).
            VideoThumbnailView(asset: asset, libraryURL: LibrarySession.shared.url(for: asset.id))
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(asset.fileName)
                        .font(.callout)
                        .lineLimit(1)
                    if isHighestRes { qualityBadge("Highest res", color: .blue) }
                    if isLargest { qualityBadge("Largest", color: .purple) }
                }
                // The at-a-glance comparison line: size · resolution · bitrate · duration.
                Text(metaLine(m))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    // Federated session: cross-library groups need "which
                    // copy am I deleting" answered right on the row.
                    if LibrarySession.shared.isFederated,
                       let owner = LibrarySession.shared.url(for: asset.id) {
                        qualityBadge(LibrarySession.shared.shortLabel(for: owner), color: .teal)
                    }
                    Text(asset.relativePath)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(asset.id) }
    }

    private func qualityBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundColor(color)
    }

    // Display formatting lives in LibraryCore (MediaFormat) so it can be unit-tested;
    // see MediaFormatTests. F6 will change where width/height/duration COME FROM —
    // these strings must not move with them.
    private func metaLine(_ m: FileMeta) -> String {
        MediaFormat.metaLine(sizeBytes: m.sizeBytes,
                             width: m.width,
                             height: m.height,
                             bitrateMbps: m.bitrateMbps,
                             durationSeconds: m.durationSeconds)
    }

    private func toggleSelection(_ id: Asset.ID) {
        if selectedForRemoval.contains(id) {
            selectedForRemoval.remove(id)
        } else {
            selectedForRemoval.insert(id)
        }
    }

    // MARK: - Scanning

    private func scan() async {
        await MainActor.run { isScanning = true; scanProgress = "Reading video info…" }
        let lib = libraryURL
        let assetList = assets
        // Federated session: the scan spans every open library, so
        // cross-library duplicates surface. Resolve each video's owning
        // library ONCE on the main actor; the detached work uses the map.
        let ownerByID: [Asset.ID: URL] = Dictionary(uniqueKeysWithValues: assetList.map {
            ($0.id, LibrarySession.shared.url(for: $0.id) ?? lib)
        })

        let (resultGroups, resultMeta) = await Task.detached(priority: .userInitiated) { () -> ([DuplicateGroup], [Asset.ID: FileMeta]) in
            // Phase 1: metadata for every video (size from the filesystem;
            // duration/resolution from the container; bitrate estimated as
            // size ÷ duration — the whole-file rate, which is what matters
            // for comparing copies).
            var meta: [Asset.ID: FileMeta] = [:]
            for (index, asset) in assetList.enumerated() {
                if index % 25 == 0 {
                    let progress = "Reading video info (\(index + 1) of \(assetList.count))…"
                    await MainActor.run { scanProgress = progress }
                }
                let url = (ownerByID[asset.id] ?? lib).appendingPathComponent(asset.relativePath)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int64, size > 0 else { continue }
                var m = FileMeta(sizeBytes: size)
                m.modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let avAsset = AVURLAsset(url: url)
                if let duration = try? await avAsset.load(.duration).seconds, duration.isFinite, duration > 0 {
                    m.durationSeconds = duration
                    m.bitrateMbps = Double(size) * 8 / duration / 1_000_000
                }
                if let track = try? await avAsset.loadTracks(withMediaType: .video).first,
                   let naturalSize = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let rendered = CGRect(origin: .zero, size: naturalSize).applying(transform)
                    m.width = Int(abs(rendered.width).rounded())
                    m.height = Int(abs(rendered.height).rounded())
                }
                meta[asset.id] = m
            }
            let byID = Dictionary(uniqueKeysWithValues: assetList.map { ($0.id, $0) })

            // Phase 2 — Tier 1: exact copies (same byte size, confirmed by
            // rounded duration when known).
            var groups: [DuplicateGroup] = []
            var inExactGroup = Set<Asset.ID>()
            var bySize: [Int64: [Asset]] = [:]
            for asset in assetList {
                guard let m = meta[asset.id] else { continue }
                bySize[m.sizeBytes, default: []].append(asset)
            }
            for (_, candidates) in bySize where candidates.count > 1 {
                var byDuration: [Int: [Asset]] = [:]
                for asset in candidates {
                    let key = meta[asset.id]?.durationSeconds.map { Int($0.rounded()) } ?? -1
                    byDuration[key, default: []].append(asset)
                }
                for (_, sameDuration) in byDuration where sameDuration.count > 1 {
                    groups.append(DuplicateGroup(confidence: .exactCopy, items: sameDuration))
                    sameDuration.forEach { inExactGroup.insert($0.id) }
                }
            }

            // Phase 3 — Tiers 2+3: one alignment engine for both re-encodes and
            // trimmed copies. Every non-exact video within trim range of a
            // neighbor gets a time-grid fingerprint (from the on-disk cache
            // when its size+mtime are unchanged); two videos match when their
            // hash sequences align at some offset — offset 0 with equal
            // lengths is a re-encode, anything else is a trimmed/overlapping
            // copy, labeled with where the shorter starts in the longer.
            let windowInput: [(id: UUID, seconds: Double)] = assetList.compactMap { asset in
                guard !inExactGroup.contains(asset.id),
                      let seconds = meta[asset.id]?.durationSeconds else { return nil }
                return (asset.id, seconds)
            }
            let windows = VideoDuplicateAnalyzer.durationWindows(
                windowInput, tolerance: VideoDuplicateAnalyzer.maxTrimSeconds)

            // ONE fingerprint store per open library: each video's print is
            // read from, written to, and saved into ITS OWNING library's
            // `.catalog/framePrints` cache — prints travel with their library
            // on detach, and the move/rename/edit lifecycle rules keep
            // working unchanged.
            var caches: [URL: FrameFingerprintStore] = [:]
            var fingerprints: [Asset.ID: [UInt64]] = [:]
            let totalCandidates = windows.reduce(0) { $0 + $1.count }
            var processed = 0
            for window in windows {
                for id in window {
                    processed += 1
                    guard let asset = byID[id], let m = meta[id] else { continue }
                    let owner = ownerByID[id] ?? lib
                    if caches[owner] == nil { caches[owner] = FrameFingerprintStore(libraryURL: owner) }
                    if let cached = caches[owner]!.validHashes(
                        relativePath: asset.relativePath, sizeBytes: m.sizeBytes, modified: m.modified) {
                        fingerprints[id] = cached
                        // Light progress so a resumed scan visibly races
                        // through the already-fingerprinted videos.
                        if processed % 25 == 0 || processed == totalCandidates {
                            let progress = "Checking cached fingerprints (\(processed) of \(totalCandidates))…"
                            await MainActor.run { scanProgress = progress }
                        }
                        continue
                    }
                    let progress = "Fingerprinting videos (\(processed) of \(totalCandidates))…"
                    await MainActor.run { scanProgress = progress }
                    let hashes = await VideoDuplicateAnalyzer.intervalFingerprint(
                        videoURL: owner.appendingPathComponent(asset.relativePath))
                    fingerprints[id] = hashes
                    caches[owner]!.setHashes(hashes, relativePath: asset.relativePath,
                                             sizeBytes: m.sizeBytes, modified: m.modified)
                    // Persist after EVERY new fingerprint: each one costs
                    // seconds of frame decoding, the save costs milliseconds —
                    // so a scan interrupted at video 600 of 1300 resumes from
                    // 600 instead of starting over.
                    caches[owner]!.save()
                }
            }
            // Final save prunes each library's entries against ITS OWN paths
            // only — one library's scan must never evict another's prints.
            for owner in caches.keys {
                let keep = Set(assetList.filter { (ownerByID[$0.id] ?? lib) == owner }.map(\.relativePath))
                caches[owner]?.save(keepingPaths: keep)
            }

            await MainActor.run { scanProgress = "Comparing fingerprints…" }
            var matchedPairs: [(UUID, UUID)] = []
            var pairAlignments: [Set<UUID>: VideoDuplicateAnalyzer.AlignmentMatch] = [:]
            for window in windows {
                for i in 0..<window.count {
                    for j in (i + 1)..<window.count {
                        let idA = window[i], idB = window[j]
                        guard let dA = meta[idA]?.durationSeconds, let dB = meta[idB]?.durationSeconds,
                              abs(dA - dB) <= VideoDuplicateAnalyzer.maxTrimSeconds,
                              let a = fingerprints[idA], let b = fingerprints[idB],
                              let alignment = VideoDuplicateAnalyzer.bestAlignment(a, b) else { continue }
                        matchedPairs.append((idA, idB))
                        pairAlignments[Set([idA, idB])] = alignment
                    }
                }
            }
            for component in VideoDuplicateAnalyzer.groupMatchedPairs(matchedPairs) {
                let items = component.compactMap { byID[$0] }
                guard items.count > 1 else { continue }
                let durations = items.compactMap { meta[$0.id]?.durationSeconds }
                let sameLength = (durations.max() ?? 0) - (durations.min() ?? 0) <= 2.0
                var note: String?
                if !sameLength, items.count == 2,
                   let alignment = pairAlignments[Set(items.map(\.id))], alignment.offsetSeconds > 0 {
                    note = "shorter copy starts \(Self.durationString(alignment.offsetSeconds)) into the longer"
                }
                groups.append(DuplicateGroup(
                    confidence: sameLength ? .visualMatch : .overlapMatch,
                    items: items, note: note))
            }

            // Exact copies first, then visual matches, biggest files first.
            let sorted = groups.sorted { lhs, rhs in
                let lExact = lhs.confidence == .exactCopy, rExact = rhs.confidence == .exactCopy
                if lExact != rExact { return lExact }
                let lSize = lhs.items.compactMap { meta[$0.id]?.sizeBytes }.max() ?? 0
                let rSize = rhs.items.compactMap { meta[$0.id]?.sizeBytes }.max() ?? 0
                return lSize > rSize
            }
            return (sorted, meta)
        }.value

        await MainActor.run {
            self.groups = resultGroups
            self.meta = resultMeta
            self.selectedForRemoval = []
            self.isScanning = false
        }
    }

    // MARK: - Deletion

    private func deleteSelected() async {
        await MainActor.run { isDeleting = true }
        let toDelete = selectedForRemoval
        let lib = libraryURL
        let assetList = assets
        // Owners resolved on the main actor; the detached work uses the map.
        let ownerByID: [Asset.ID: URL] = Dictionary(uniqueKeysWithValues: assetList.map {
            ($0.id, LibrarySession.shared.url(for: $0.id) ?? lib)
        })

        // Route through the shared delete (file-first ordering: a failed file
        // removal aborts that video with its metadata intact; artifacts and
        // marker previews are cleaned up; the file goes to the Trash).
        let (deleted, failures) = await Task.detached(priority: .userInitiated) { () -> (Set<Asset.ID>, [String]) in
            let service = VideoTransferService()
            var deleted = Set<Asset.ID>()
            var failures: [String] = []
            for id in toDelete {
                guard let asset = assetList.first(where: { $0.id == id }) else { continue }
                do {
                    // Deletion lands in the asset's OWNING library.
                    try service.deleteVideoAndArtifacts(
                        asset, in: ownerByID[id] ?? lib, toTrash: true)
                    deleted.insert(id)
                } catch {
                    failures.append("\(asset.fileName): \(error.localizedDescription)")
                }
            }
            return (deleted, failures)
        }.value

        await MainActor.run {
            // Prune deleted items in place; groups that drop below two
            // remaining copies are no longer duplicates.
            groups = groups.compactMap { group in
                let remaining = group.items.filter { !deleted.contains($0.id) }
                guard remaining.count > 1 else { return nil }
                var updated = group
                updated.items = remaining
                return updated
            }
            selectedForRemoval.removeAll()
            isDeleting = false
            if !failures.isEmpty {
                errorMessage = "\(failures.count) couldn't be deleted (kept in the library):\n" + failures.prefix(5).joined(separator: "\n")
            }
            onRefresh()
        }
    }

    // MARK: - Formatting

    private func byteString(_ bytes: Int64) -> String {
        MediaFormat.byteCount(bytes)
    }

    // Static + nonisolated so the background scan closure can format the
    // overlap-offset note without touching main-actor state.
    nonisolated private static func durationString(_ seconds: Double) -> String {
        MediaFormat.duration(seconds: seconds)
    }
}
