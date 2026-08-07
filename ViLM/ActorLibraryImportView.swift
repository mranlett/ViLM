// ActorLibraryImportView.swift
// Settings tool: reads a .vilmactors package, shows a preview-before-commit
// merge plan (new/updated actors, new/duplicate photos), and applies it via
// LibraryStore.applyActorMerge. Nothing is written until Apply.

import SwiftUI
import LibraryCore

struct ActorLibraryImportView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let onRefresh: () -> Void

    @State private var isShowingPicker = true
    @State private var isLoading = false
    @State private var export: ActorLibraryExport?
    @State private var plan: ActorMergePlan?
    @State private var isApplying = false
    @State private var result: GraphMergeResult?
    @State private var errorMessage: String?

    /// An entity id as a person reads it: `studio:Coast Line` becomes
    /// `Coast Line`. Anything without a known prefix is left alone.
    private func readable(_ value: String) -> String {
        for prefix in ["actor:", "studio:", "tag:", "series:"] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import & Merge Actors")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(result != nil ? "Done" : "Close") {
                            if result != nil { onRefresh() }
                            dismiss()
                        }
                    }
                    if plan != nil, result == nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Apply") { Task { await apply() } }
                                .disabled(isApplying)
                        }
                    }
                }
                .overlay {
                    if isApplying {
                        ProgressView("Merging…")
                            .padding().background(.regularMaterial).cornerRadius(10)
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil; if export == nil { dismiss() } } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: { Text(errorMessage ?? "") }
                .fileImporter(
                    isPresented: $isShowingPicker,
                    allowedContentTypes: [.actorLibraryPackage],
                    allowsMultipleSelection: false
                ) { pickerResult in
                    switch pickerResult {
                    case .success(let urls):
                        guard let url = urls.first else { dismiss(); return }
                        Task { await load(from: url) }
                    case .failure(let error):
                        errorMessage = "\(error.localizedDescription)"
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Reading export…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.green)
                Text("Merge Complete")
                    .font(.title3.bold())
                Group {
                    Text("\(result.actors.new) new actor\(result.actors.new == 1 ? "" : "s"), \(result.actors.updated) updated")
                    Text("\(result.actors.photos) new photo\(result.actors.photos == 1 ? "" : "s")")
                    // The rest of the graph, reported separately: these are the
                    // parts a sync used to leave behind entirely.
                    Text("\(result.newStudios) new studio\(result.newStudios == 1 ? "" : "s"), \(result.updatedStudios) confirmed")
                    Text("\(result.newTags) new tag\(result.newTags == 1 ? "" : "s"), \(result.classifiedTags) classified")
                    Text("\(result.newPerformerTags + result.newStudioParents) new connection\(result.newPerformerTags + result.newStudioParents == 1 ? "" : "s")")
                    // Counted apart from the connections above, deliberately.
                    // Neither of these is a new relationship — one dates a
                    // relationship both libraries already agreed on, the other
                    // is a former ownership — and folding them into one number
                    // would make the total mean nothing in particular.
                    if result.datedStudioParents > 0 {
                        Text("\(result.datedStudioParents) studio\(result.datedStudioParents == 1 ? "" : "s") gained a start date")
                    }
                    if result.newStudioParentPeriods > 0 {
                        Text("\(result.newStudioParentPeriods) former owner\(result.newStudioParentPeriods == 1 ? "" : "s") recorded")
                    }
                    if result.newMatches > 0 {
                        Text("\(result.newMatches) external identit\(result.newMatches == 1 ? "y" : "ies") learned")
                    }
                }
                .foregroundColor(.secondary)

                // ⚠️ Shown, never resolved. Both libraries keep what they had;
                // this is the only place the operator learns they differ.
                if !result.disagreements.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(result.disagreements.count) disagreement\(result.disagreements.count == 1 ? "" : "s") — nothing changed for these")
                            .font(.callout).foregroundStyle(.orange)
                        ForEach(result.disagreements) { item in
                            // ⚠️ Prefixes stripped. A studio disagreement names
                            // entity ids, so this read "studio:Coast Line: here
                            // “studio:Old Network”" — the operator does not
                            // think in node ids and should not have to.
                            Text("\(readable(item.name)): here “\(readable(item.mine))”, there “\(readable(item.theirs))”")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                if result.refusedCycles > 0 {
                    Text("\(result.refusedCycles) studio parent\(result.refusedCycles == 1 ? "" : "s") skipped — taking them would have made a loop")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let plan {
            planView(plan)
        } else {
            Color.clear
        }
    }

    private func planView(_ plan: ActorMergePlan) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(plan.newActorCount) new actor\(plan.newActorCount == 1 ? "" : "s"), \(plan.updatedActorCount) will be updated")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("\(plan.totalNewPhotos) new photo\(plan.totalNewPhotos == 1 ? "" : "s") to add, \(plan.totalDuplicatePhotos) duplicate\(plan.totalDuplicatePhotos == 1 ? "" : "s") will be skipped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Updated actors have their bio, tags, and other details fully replaced by the import. Photos are only ever added, never removed. Nothing is written until you tap Apply.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Section {
                ForEach(plan.changes) { change in
                    HStack {
                        Image(systemName: change.isNew ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundColor(change.isNew ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.displayName)
                            if change.newPhotoCount > 0 || change.duplicatePhotoCount > 0 {
                                Text(photoSummary(change))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(change.isNew ? "New" : "Update")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func photoSummary(_ change: ActorMergePlan.ActorChange) -> String {
        var parts: [String] = []
        if change.newPhotoCount > 0 { parts.append("\(change.newPhotoCount) new photo\(change.newPhotoCount == 1 ? "" : "s")") }
        if change.duplicatePhotoCount > 0 { parts.append("\(change.duplicatePhotoCount) duplicate\(change.duplicatePhotoCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func load(from pickedURL: URL) async {
        isLoading = true
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: pickedURL)
            let loadedExport = try JSONDecoder().decode(ActorLibraryExport.self, from: data)
            let url = libraryURL
            let computedPlan = try await Task.detached(priority: .userInitiated) {
                let store = try LibraryStore(at: url)
                return try store.planActorMerge(loadedExport)
            }.value
            await MainActor.run {
                self.export = loadedExport
                self.plan = computedPlan
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }

    private func apply() async {
        guard let export else { return }
        isApplying = true
        do {
            let url = libraryURL
            let applied = try await Task.detached(priority: .userInitiated) {
                let store = try LibraryStore(at: url)
                return try store.applyGraphMerge(export)
            }.value
            await MainActor.run {
                self.result = applied
                self.isApplying = false
            }
        } catch {
            await MainActor.run {
                self.isApplying = false
                self.errorMessage = "Merge failed: \(error.localizedDescription)"
            }
        }
    }
}
