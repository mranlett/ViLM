// DuplicateDetectionView.swift
// Settings tool: groups videos by exact file size (confirmed by duration) to
// find likely duplicates, and deletes user-selected copies from disk and the
// library.

import SwiftUI
import LibraryCore
import AVFoundation

struct DuplicateDetectionView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let assets: [Asset]
    let onRefresh: () -> Void

    struct DuplicateGroup: Identifiable, Sendable {
        let id = UUID()
        let sizeBytes: Int64
        let durationSeconds: Double?
        var items: [Asset]
    }

    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = true
    @State private var selectedForRemoval: Set<Asset.ID> = []
    @State private var isDeleting = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String? = nil

    private var duplicateCount: Int {
        // Total files that are copies (every group member beyond the first).
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
                    Text("This permanently deletes \(selectedForRemoval.count) video file(s) from disk and removes them from the library. This cannot be undone.")
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
        .frame(minWidth: 500, minHeight: 400)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            ProgressView("Scanning for duplicates…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            ContentUnavailableView(
                "No Duplicates Found",
                systemImage: "checkmark.seal",
                description: Text("No videos share the same file size and duration.")
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
                            row(for: asset)
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack {
            Text(byteString(group.sizeBytes))
            if let duration = group.durationSeconds {
                Text("· \(durationString(duration))")
            }
            Spacer()
            Text("\(group.items.count) copies")
        }
        .font(.caption)
    }

    private func row(for asset: Asset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selectedForRemoval.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selectedForRemoval.contains(asset.id) ? .red : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.fileName)
                    .font(.callout)
                    .lineLimit(1)
                Text(asset.relativePath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(asset.id) }
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
        await MainActor.run { isScanning = true }
        let lib = libraryURL
        let assetList = assets

        let result = await Task.detached(priority: .userInitiated) { () -> [DuplicateGroup] in
            // 1. Group by exact byte size (fast; from filesystem attributes).
            var bySize: [Int64: [Asset]] = [:]
            for asset in assetList {
                let url = lib.appendingPathComponent(asset.relativePath)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int64, size > 0 else { continue }
                bySize[size, default: []].append(asset)
            }

            // 2. For each size collision, confirm by duration (avoids the rare
            //    case of two different videos with identical byte counts).
            var groups: [DuplicateGroup] = []
            for (size, candidates) in bySize where candidates.count > 1 {
                var byDuration: [Int: [Asset]] = [:]
                var unknownDuration: [Asset] = []
                for asset in candidates {
                    let url = lib.appendingPathComponent(asset.relativePath)
                    if let duration = await Self.loadDuration(url), duration > 0 {
                        byDuration[Int(duration.rounded()), default: []].append(asset)
                    } else {
                        unknownDuration.append(asset)
                    }
                }
                for (seconds, group) in byDuration where group.count > 1 {
                    groups.append(DuplicateGroup(sizeBytes: size, durationSeconds: Double(seconds), items: group))
                }
                // Same size but duration couldn't be read — still likely dupes.
                if unknownDuration.count > 1 {
                    groups.append(DuplicateGroup(sizeBytes: size, durationSeconds: nil, items: unknownDuration))
                }
            }
            return groups.sorted { $0.sizeBytes > $1.sizeBytes }
        }.value

        await MainActor.run {
            self.groups = result
            self.selectedForRemoval = []
            self.isScanning = false
        }
    }

    private static func loadDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }

    // MARK: - Deletion

    private func deleteSelected() async {
        await MainActor.run { isDeleting = true }
        let deleted = selectedForRemoval
        do {
            let store = try LibraryStore(at: libraryURL)
            let fileManager = FileManager.default
            for id in deleted {
                guard let asset = assets.first(where: { $0.id == id }) else { continue }
                let url = libraryURL.appendingPathComponent(asset.relativePath)
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
                try store.deleteAsset(asset)
            }
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
                onRefresh()
            }
        } catch {
            await MainActor.run {
                isDeleting = false
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Formatting

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
