// LibraryBackupView.swift
// Settings tool: back up the open library's catalog to a single .vilmbackup
// archive, or restore a backup. Restore targets either a brand-new empty
// folder, or an existing library (a non-destructive field merge with a
// preview + per-item keep/discard for videos added since the backup). Video
// files are not included (catalog durability only). LibraryBackupService does
// the archive/verify/restore/merge work; this view is the pickers + preview.

import SwiftUI
import UniformTypeIdentifiers
import LibraryCore

/// A .vilmbackup archive, referenced by a temp file URL so the (potentially
/// large) archive is streamed to the save destination rather than loaded into
/// memory.
struct BackupDocument: FileDocument {
    static let backupType = UTType(filenameExtension: "vilmbackup") ?? .data
    static var readableContentTypes: [UTType] { [backupType] }

    var sourceURL: URL?
    init(sourceURL: URL) { self.sourceURL = sourceURL }
    init(configuration: ReadConfiguration) throws { self.sourceURL = nil }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let sourceURL else { throw CocoaError(.fileNoSuchFile) }
        return try FileWrapper(url: sourceURL)
    }
}

struct LibraryBackupView: View {
    @Environment(\.dismiss) private var dismiss

    let openLibraryURL: URL
    /// Called when a restore/merge finishes; ContentView opens the library.
    let onRestored: (URL) -> Void

    enum Mode: String, CaseIterable { case backUp = "Back Up", restore = "Restore" }
    @State private var mode: Mode = .backUp
    @State private var errorMessage: String?

    // Back up
    @State private var isBuilding = false
    @State private var archiveURL: URL?
    @State private var isShowingSaveSheet = false
    @State private var didSave = false

    // Restore
    @State private var isShowingArchivePicker = false
    @State private var pickedArchiveURL: URL?
    @State private var isShowingFolderPicker = false
    @State private var isRestoring = false
    @State private var restoreStatus = ""
    @State private var restoredURL: URL?

    // Merge (restore over an existing library)
    @State private var mergePlan: LibraryBackupService.LibraryRestorePlan?
    @State private var mergeTarget: URL?
    @State private var discardIDs: Set<UUID> = []

    // Security-scoped URLs held open across a merge (plan → apply).
    @State private var scopedArchive: URL?
    @State private var scopedTarget: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if mergePlan == nil && restoredURL == nil {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).padding()
                }
                content
                Spacer(minLength: 0)
            }
            .navigationTitle("Backup & Restore")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() } } }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .fileExporter(
                isPresented: $isShowingSaveSheet,
                document: archiveURL.map(BackupDocument.init(sourceURL:)),
                contentType: BackupDocument.backupType,
                defaultFilename: defaultBackupName
            ) { result in
                if case .failure(let error) = result { errorMessage = "Save failed: \(error.localizedDescription)" }
                else { didSave = true }
            }
            .fileImporter(isPresented: $isShowingArchivePicker, allowedContentTypes: [BackupDocument.backupType]) {
                handlePickedArchive($0)
            }
            .fileImporter(isPresented: $isShowingFolderPicker, allowedContentTypes: [.folder]) {
                handlePickedFolder($0)
            }
            .onDisappear { releaseScopes() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if isRestoring {
            centered { ProgressView(restoreStatus.isEmpty ? "Working…" : restoreStatus) }
        } else if let restoredURL {
            resultView(icon: "checkmark.circle.fill", tint: .green, title: "Done",
                       message: "Restored into “\(restoredURL.lastPathComponent)”. Open it to reconnect your video files — any that aren't found are flagged as missing.") {
                Button("Open Library") { onRestored(restoredURL); dismiss() }.buttonStyle(.borderedProminent)
            }
        } else if let plan = mergePlan {
            mergePreview(plan)
        } else {
            switch mode {
            case .backUp: backUpSection
            case .restore: restoreSection
            }
        }
    }

    // MARK: - Back up

    @ViewBuilder
    private var backUpSection: some View {
        if isBuilding {
            centered { ProgressView("Creating and verifying backup…")
                Text("Compressing the catalog (database, thumbnails, profile & marker images). Videos are not included.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32) }
        } else if didSave {
            resultView(icon: "checkmark.circle.fill", tint: .green, title: "Backup Saved",
                       message: "Saved a backup of “\(openLibraryURL.lastPathComponent)”.")
        } else {
            centered {
                Image(systemName: "externaldrive.badge.timemachine").font(.system(size: 44)).foregroundColor(.accentColor)
                Text("Back Up This Library").font(.title3.bold())
                Text("Archives the catalog — database, thumbnails, and profile/marker images — into a single file. Video files are not included.")
                    .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Create Backup…") { Task { await buildBackup() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func buildBackup() async {
        isBuilding = true
        let url = openLibraryURL
        do {
            let result = try await Task.detached(priority: .userInitiated) { try LibraryBackupService().exportBackup(of: url) }.value
            await MainActor.run { archiveURL = result.archiveURL; isBuilding = false; isShowingSaveSheet = true }
        } catch {
            await MainActor.run { isBuilding = false; errorMessage = "Couldn't create the backup: \(error.localizedDescription)" }
        }
    }

    // MARK: - Restore (pickers)

    private var restoreSection: some View {
        centered {
            Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 44)).foregroundColor(.accentColor)
            Text("Restore a Backup").font(.title3.bold())
            Text("Pick a .vilmbackup file, then a destination folder. An empty folder is restored fresh; an existing library is merged (with a preview first).")
                .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            if let pickedArchiveURL {
                Label(pickedArchiveURL.lastPathComponent, systemImage: "doc.zipper").font(.caption).foregroundColor(.secondary)
                Button("Choose Destination Folder…") { isShowingFolderPicker = true }.buttonStyle(.borderedProminent)
            } else {
                Button("Choose Backup File…") { isShowingArchivePicker = true }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func handlePickedArchive(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): errorMessage = "Couldn't open that file: \(error.localizedDescription)"
        case .success(let url):
            releaseScopes()
            if url.startAccessingSecurityScopedResource() { scopedArchive = url }
            pickedArchiveURL = url
        }
    }

    private func handlePickedFolder(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): errorMessage = "Couldn't open that folder: \(error.localizedDescription)"
        case .success(let target):
            guard let archive = pickedArchiveURL else { return }
            if target.startAccessingSecurityScopedResource() { scopedTarget = target }
            let catalog = target.appendingPathComponent(".catalog")
            if FileManager.default.fileExists(atPath: catalog.path) {
                Task { await planMerge(archive: archive, target: target) } // existing library → merge
            } else {
                Task { await restoreIntoEmpty(archive: archive, target: target) }
            }
        }
    }

    private func restoreIntoEmpty(archive: URL, target: URL) async {
        isRestoring = true; restoreStatus = "Restoring…"
        do {
            try await Task.detached(priority: .userInitiated) {
                try LibraryBackupService().restoreIntoEmpty(archiveURL: archive, targetLibraryURL: target)
            }.value
            await MainActor.run { isRestoring = false; restoredURL = target }
        } catch {
            await MainActor.run { isRestoring = false; errorMessage = "Restore failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - Merge (restore over an existing library)

    private func planMerge(archive: URL, target: URL) async {
        isRestoring = true; restoreStatus = "Analyzing backup…"
        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                try LibraryBackupService().planRestore(archiveURL: archive, destinationLibraryURL: target)
            }.value
            await MainActor.run { isRestoring = false; mergeTarget = target; mergePlan = plan; discardIDs = [] }
        } catch {
            await MainActor.run { isRestoring = false; errorMessage = "Couldn't analyze the backup: \(error.localizedDescription)" }
        }
    }

    private func mergePreview(_ plan: LibraryBackupService.LibraryRestorePlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Merge into “\(mergeTarget?.lastPathComponent ?? "")”").font(.headline)
                Text("\(plan.newAssetCount) video\(plan.newAssetCount == 1 ? "" : "s") restored · \(plan.updatedAssetCount) merged · \(plan.newActorCount) new actor\(plan.newActorCount == 1 ? "" : "s"). Existing metadata is never overwritten by empty values; tags are combined.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal).padding(.top, 8)

            if plan.destinationOnlyAssets.isEmpty {
                Spacer(minLength: 12)
            } else {
                Text("Videos added since this backup (\(plan.destinationOnlyAssets.count)) — keep, or discard to revert to the backup:")
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal).padding(.top, 10)
                List {
                    ForEach(plan.destinationOnlyAssets, id: \.id) { asset in
                        HStack {
                            Text(asset.videoName ?? asset.fileName).lineLimit(1)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { discardIDs.contains(asset.id) ? 1 : 0 },
                                set: { if $0 == 1 { discardIDs.insert(asset.id) } else { discardIDs.remove(asset.id) } }
                            )) { Text("Keep").tag(0); Text("Discard").tag(1) }
                            .pickerStyle(.segmented).frame(width: 160)
                        }
                    }
                }
            }

            Button {
                Task { await applyMerge() }
            } label: {
                Text("Apply Merge").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).padding()
        }
    }

    private func applyMerge() async {
        guard let archive = pickedArchiveURL, let target = mergeTarget else { return }
        isRestoring = true; restoreStatus = "Merging…"
        let discards = discardIDs
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try LibraryBackupService().applyRestoreOverExisting(
                    archiveURL: archive, destinationLibraryURL: target, discardAssetIDs: discards)
            }.value
            await MainActor.run { isRestoring = false; mergePlan = nil; restoredURL = target }
        } catch {
            await MainActor.run { isRestoring = false; errorMessage = "Merge failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - Shared

    private func finish() { releaseScopes(); dismiss() }

    private func releaseScopes() {
        if let s = scopedArchive { s.stopAccessingSecurityScopedResource(); scopedArchive = nil }
        if let s = scopedTarget { s.stopAccessingSecurityScopedResource(); scopedTarget = nil }
    }

    private var defaultBackupName: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return "\(openLibraryURL.lastPathComponent)-\(formatter.string(from: Date())).vilmbackup"
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func resultView(icon: String, tint: Color, title: String, message: String,
                            @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        centered {
            Image(systemName: icon).font(.system(size: 44)).foregroundColor(tint)
            Text(title).font(.title3.bold())
            Text(message).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            action()
        }
    }
}
