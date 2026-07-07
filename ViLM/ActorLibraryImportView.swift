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
    @State private var result: ActorMergeResult?
    @State private var errorMessage: String?

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
        .frame(minWidth: 520, minHeight: 420)
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
                Text("\(result.newActorCount) new actor\(result.newActorCount == 1 ? "" : "s"), \(result.updatedActorCount) updated")
                Text("\(result.newPhotoCount) new photo\(result.newPhotoCount == 1 ? "" : "s"), \(result.duplicatePhotoCount) duplicate\(result.duplicatePhotoCount == 1 ? "" : "s") skipped")
                    .foregroundColor(.secondary)
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
                return try store.applyActorMerge(export)
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
