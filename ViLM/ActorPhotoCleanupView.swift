// ActorPhotoCleanupView.swift
// Finds redundant actor profile photos and removes the ones the user approves.
//
// Two safety rules drive the layout:
//
//   Nothing is deleted without being seen. Every group shows the survivor
//   beside what would go, at a size where you can tell two similar photos
//   apart. A list of file names would be unreviewable.
//
//   Visual matches start UNTICKED. Identical bytes need no judgement — the
//   survivor is exactly what was removed. A same-picture-different-size match
//   is a claim, and a wrong one deletes a photo that cannot be recovered.

import SwiftUI
import LibraryCore

struct ActorPhotoCleanupView: View {
    let libraryURL: URL
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var report: ActorPhotoScanReport?
    @State private var isScanning = false
    @State private var progress: (done: Int, total: Int) = (0, 0)
    @State private var approved: Set<String> = []      // keyed by group identity
    @State private var isApplying = false
    @State private var summary: String?

    private func key(_ group: DuplicatePhotoGroup) -> String { group.id }

    private var groups: [DuplicatePhotoGroup] { report?.groups ?? [] }
    private var selected: [DuplicatePhotoGroup] { groups.filter { approved.contains(key($0)) } }
    private var selectedBytes: Int { selected.reduce(0) { $0 + $1.reclaimedBytes } }

    var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    scanning
                } else if let summary {
                    ContentUnavailableView(summary, systemImage: "checkmark.circle")
                } else if report == nil {
                    ContentUnavailableView("Ready to scan",
                                           systemImage: "photo.stack",
                                           description: Text("Looks for the same actor photo stored more than once."))
                } else if groups.isEmpty {
                    ContentUnavailableView("No duplicate photos",
                                           systemImage: "checkmark.circle",
                                           description: Text("Scanned \(report?.filesScanned ?? 0) photos across \(report?.actorsScanned ?? 0) actors."))
                } else {
                    groupList
                }
            }
            .navigationTitle("Duplicate Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onFinish(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if report == nil {
                        Button("Scan") { scan() }.disabled(isScanning)
                    } else if !groups.isEmpty {
                        Button(isApplying ? "Removing…" : "Remove \(selected.reduce(0) { $0 + $1.remove.count })") {
                            apply()
                        }
                        .disabled(selected.isEmpty || isApplying)
                    }
                }
            }
        }
        // Rows carry photo thumbnails side by side — the whole judgement is
        // "are these the same picture", which needs room to be visible.
        .macSheet(minWidth: 760, minHeight: 580)
        .onAppear { if report == nil && !isScanning { scan() } }
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(maxWidth: 320)
            Text("Scanning \(progress.done) of \(progress.total) actors")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                if !exactGroups.isEmpty {
                    Section {
                        ForEach(exactGroups) { row($0) }
                    } header: {
                        Text("Identical files — \(exactGroups.count)")
                    } footer: {
                        Text("Byte-for-byte copies. The kept photo is exactly what would be removed.")
                    }
                }
                if !visualGroups.isEmpty {
                    Section {
                        ForEach(visualGroups) { row($0) }
                    } header: {
                        Text("Same photo, different size — \(visualGroups.count)")
                    } footer: {
                        Text("These look like the same picture at different resolutions, and the largest is kept. Check each one before removing — this cannot be undone.")
                    }
                }
            }
        }
    }

    private var exactGroups: [DuplicatePhotoGroup] { groups.filter { !$0.isVisualMatch } }
    private var visualGroups: [DuplicatePhotoGroup] { groups.filter(\.isVisualMatch) }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(groups.reduce(0) { $0 + $1.remove.count }) removable photos")
                    .font(.headline)
                Text("\(byteText(selectedBytes)) selected of \(byteText(report?.reclaimableBytes ?? 0))")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Select Identical") {
                approved.formUnion(exactGroups.map(key))
            }
            Button("Deselect All") { approved.removeAll() }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func row(_ group: DuplicatePhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(
                    get: { approved.contains(key(group)) },
                    set: { on in
                        if on { approved.insert(key(group)) } else { approved.remove(key(group)) }
                    }
                )) {
                    Text(displayName(group.actorId)).font(.subheadline).fontWeight(.medium)
                }
                Spacer()
                if group.changesPrimary {
                    // Worth calling out: this one visibly changes the actor's
                    // portrait, not just their gallery.
                    Label("Profile photo changes", systemImage: "person.crop.circle")
                        .font(.caption2).foregroundColor(.orange)
                }
                Text(byteText(group.reclaimedBytes)).font(.caption).foregroundColor(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    thumb(group.actorId, group.keep, keeping: true)
                    ForEach(group.remove, id: \.token) { thumb(group.actorId, $0, keeping: false) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func thumb(_ actorId: String, _ photo: PhotoMeasurement, keeping: Bool) -> some View {
        VStack(spacing: 4) {
            ProfileImageView(libraryURL: libraryURL, entityId: actorId,
                             photoUrl: photo.token, isGallery: !photo.isPrimary) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 84, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(keeping ? Color.green : Color.red.opacity(0.7), lineWidth: 2)
            )
            .opacity(keeping ? 1 : 0.55)

            Text(keeping ? "Keep" : "Remove")
                .font(.caption2).fontWeight(.semibold)
                .foregroundColor(keeping ? .green : .red)
            // The number that justifies the choice.
            Text(photo.pixelCount > 0 ? "\(photo.pixelCount / 1000)k px" : "—")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    /// ⚠️ Derived from the id, and correct only until the re-key.
    ///
    /// This screen is handed bare actor ids from a photo scan and has no
    /// profile in scope, so there is nothing better to read here yet. After
    /// the re-key it will show uids — the scan needs to carry the name, the
    /// same way `ActorSyncPlan` and `AliasSplitCandidate.Claimant` now do.
    private func displayName(_ actorId: String) -> String {
        actorId.hasPrefix("actor:") ? String(actorId.dropFirst(6)) : actorId
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Work

    private func scan() {
        isScanning = true
        summary = nil
        let url = libraryURL
        Task.detached(priority: .utility) {
            do {
                let store = try LibraryStore(at: url)
                let result = try ActorPhotoScanner.scan(store: store, libraryURL: url) { done, total in
                    Task { @MainActor in progress = (done, total) }
                }
                await MainActor.run {
                    report = result
                    // Identical files are pre-approved; visual matches are not.
                    approved = Set(result.groups.filter { !$0.isVisualMatch }.map(key))
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    isScanning = false
                    AppErrorReporter.report("Couldn't scan photos: \(error.localizedDescription)")
                }
            }
        }
    }

    private func apply() {
        isApplying = true
        let chosen = selected
        let url = libraryURL
        Task.detached(priority: .utility) {
            do {
                let store = try LibraryStore(at: url)
                let removed = try ActorPhotoScanner.apply(chosen, store: store, libraryURL: url)
                let freed = chosen.reduce(0) { $0 + $1.reclaimedBytes }
                await MainActor.run {
                    isApplying = false
                    summary = "Removed \(removed) photo\(removed == 1 ? "" : "s"), freeing \(byteText(freed))."
                    report = nil
                    approved.removeAll()
                    NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
                }
            } catch {
                await MainActor.run {
                    isApplying = false
                    AppErrorReporter.report("Couldn't remove photos: \(error.localizedDescription)")
                }
            }
        }
    }
}
