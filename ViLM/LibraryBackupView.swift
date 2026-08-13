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

/// The `.vilmbackup` document type.
///
/// 🚨 Declared, not looked up. This read
/// `UTType(filenameExtension: "vilmbackup") ?? .data`, and because nothing in
/// the app declared the type the lookup returned nil and the `?? .data` quietly
/// took over — every export was announced as plain `public.data` under a
/// `.vilmbackup` filename. A fallback that changes what the app claims to be
/// exporting is not a safe default.
///
/// ⚠️ The identifier must match `UTExportedTypeDeclarations` in
/// `Config/Info.plist` exactly.
///
/// ⭐ This was a `FileDocument` whose `fileWrapper` returned
/// `FileWrapper(url:)`. That is a LAZY reference, and `fileExporter` hands it
/// to the document picker, which runs out of process — so the picker tried to
/// open a path inside this app's container and was refused:
///
///     The file "vilmbackup-<uuid>.vilmbackup" couldn't be opened because
///     you don't have permission to view it.
///
/// The tell was the save sheet offering that raw UUID name instead of
/// `defaultFilename`: the wrapper's `preferredFilename` was winning, which only
/// happens when the document IS a file reference. Export now goes through
/// `.fileMover`, which is the API for handing the system a file that already
/// exists on disk — it coordinates the move across the sandbox rather than
/// asking another process to read our container, and it never loads a
/// multi-gigabyte archive into memory to do it.
enum BackupArchive {
    static let type = UTType(exportedAs: "com.mattranlett.ViLM.backup",
                             conformingTo: .data)
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
    /// 🚨 The archive being exported, and the ONLY thing that decides whether
    /// the save sheet is up.
    ///
    /// This used to be two independent pieces of state — `archiveURL` plus an
    /// `isShowingSaveSheet` flag — and they were allowed to disagree. The
    /// exporter's completion handler nilled the URL while the flag was still
    /// true, so SwiftUI re-evaluated the body with `isPresented == true` and
    /// `document == nil`, logged "Attempting to export a nil document", and
    /// dismissed the picker on its own. Every retry re-entered the same state
    /// immediately, which is what "the save window closes itself" was.
    ///
    /// ⚠️ Presentation is DERIVED from this below rather than tracked beside
    /// it. Two states that must agree will eventually not.
    @State private var archiveURL: URL?
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
            .fileMover(
                // ⭐ Derived, so presentation and the file cannot contradict
                // each other. They used to be an `isShowingSaveSheet` flag
                // beside an optional URL, and the completion handler nilled the
                // URL while the flag was still true — SwiftUI then re-evaluated
                // the body with `isPresented == true` and nothing to export,
                // logged "Attempting to export a nil document", and dismissed
                // the picker itself.
                isPresented: Binding(get: { archiveURL != nil },
                                     set: { if !$0 { archiveURL = nil } }),
                file: archiveURL
            ) { result in
                if case .failure(let error) = result {
                    // ⚠️ The domain and code as well as the description. The
                    // description alone said "you do not have permission to
                    // view it", which named neither the failing side nor the
                    // reason, and sent this diagnosis down three wrong paths.
                    let ns = error as NSError
                    errorMessage = "Save failed: \(error.localizedDescription) "
                        + "[\(ns.domain) \(ns.code)]"
                } else { didSave = true }
                // ⚠️ A successful move has already taken the file; this clears
                // up after a cancel or a failure. The enclosing temp directory
                // goes too — these are multi-hundred-MB archives that otherwise
                // linger until an OS purge (DEFECT_INVENTORY M3).
                //
                // The FILE is removed here; the STATE is cleared by the binding
                // above, never from inside this handler.
                deleteTempArchiveFile()
            }
            .fileImporter(isPresented: $isShowingArchivePicker, allowedContentTypes: [BackupArchive.type]) {
                handlePickedArchive($0)
            }
            .fileImporter(isPresented: $isShowingFolderPicker, allowedContentTypes: [.folder]) {
                handlePickedFolder($0)
            }
            .onDisappear { releaseScopes() }
        }
        // A swipe-dismiss mid-operation shouldn't be possible at all; and if
        // the view *is* torn down some other way, each operation holds its own
        // security-scope claims (ScopedOperation), so releasing ours above
        // can't cut off in-flight file access (DEFECT_INVENTORY H5).
        .interactiveDismissDisabled(isBuilding || isRestoring)
        .macSheet(minWidth: 480, minHeight: 460)
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
        deleteTempArchive() // a re-run after a cancelled save must not leak the prior archive
        isBuilding = true
        let url = openLibraryURL
        do {
            let result = try await ScopedOperation.run(holding: [url]) {
                try await Task.detached(priority: .userInitiated) { try LibraryBackupService().exportBackup(of: url) }.value
            }
            // 🚨 Renamed BEFORE the picker sees it. `.fileMover` offers the
            // file's own name, and the service names its temp archive
            // `vilmbackup-<uuid>.vilmbackup` — which is what the save sheet
            // was putting in front of the operator.
            let named = (try? Self.renamed(result.archiveURL, to: defaultBackupName))
                ?? result.archiveURL
            await MainActor.run { isBuilding = false; archiveURL = named }
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
            try await ScopedOperation.run(holding: [archive, target]) {
                try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService().restoreIntoEmpty(archiveURL: archive, targetLibraryURL: target)
                }.value
            }
            await MainActor.run { isRestoring = false; restoredURL = target }
        } catch {
            await MainActor.run { isRestoring = false; errorMessage = "Restore failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - Merge (restore over an existing library)

    private func planMerge(archive: URL, target: URL) async {
        isRestoring = true; restoreStatus = "Analyzing backup…"
        do {
            let plan = try await ScopedOperation.run(holding: [archive, target]) {
                try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService().planRestore(archiveURL: archive, destinationLibraryURL: target)
                }.value
            }
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
            try await ScopedOperation.run(holding: [archive, target]) {
                try await Task.detached(priority: .userInitiated) {
                    _ = try LibraryBackupService().applyRestoreOverExisting(
                        archiveURL: archive, destinationLibraryURL: target, discardAssetIDs: discards)
                }.value
            }
            await MainActor.run { isRestoring = false; mergePlan = nil; restoredURL = target }
        } catch {
            await MainActor.run { isRestoring = false; errorMessage = "Merge failed: \(error.localizedDescription)" }
        }
    }

    // MARK: - Shared

    private func finish() { releaseScopes(); deleteTempArchive(); dismiss() }

    /// Removes the exported temp .vilmbackup once it's saved, failed, or
    /// abandoned (sheet dismissed / save sheet cancelled — cancellation
    /// doesn't invoke the fileExporter callback, so finish() covers it).
    /// Moves the built archive under the name a person should see, inside its
    /// own temp directory so two runs cannot collide on the same filename.
    private static func renamed(_ url: URL, to filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vilmbackup-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Removes the temp archive and the directory holding it, WITHOUT touching
    /// `archiveURL` — that is the presentation state, and clearing it from
    /// inside the completion handler is what caused the nil-document defect.
    private func deleteTempArchiveFile() {
        guard let archiveURL else { return }
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent())
    }

    private func deleteTempArchive() {
        deleteTempArchiveFile()
        archiveURL = nil
    }

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
