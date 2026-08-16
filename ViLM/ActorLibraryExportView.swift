// ActorLibraryExportView.swift
// Settings tool: packages every actor profile and its cached photos into a
// single .vilmactors file for merging into another library copy
// (LibraryStore.exportActorLibrary does the heavy lifting).

import SwiftUI
import LibraryCore

struct ActorLibraryExportView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL

    @State private var isBuilding = true
    @State private var export: ActorLibraryExport?
    @State private var errorMessage: String?
    @State private var isShowingSaveSheet = false
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Export Actor Library")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(didSave ? "Done" : "Close") { dismiss() }
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: { Text(errorMessage ?? "") }
                .task { await buildExport() }
                .fileExporter(
                    isPresented: $isShowingSaveSheet,
                    document: export.map(ActorLibraryDocument.init),
                    contentType: .actorLibraryPackage,
                    defaultFilename: defaultFilename
                ) { result in
                    switch result {
                    case .success: didSave = true
                    case .failure(let error): errorMessage = "Save failed: \(error.localizedDescription)"
                    }
                }
        }
        .macSheet(minWidth: 420, minHeight: 280)
    }

    @ViewBuilder
    private var content: some View {
        if isBuilding {
            ProgressView("Gathering actor data and photos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let export {
            VStack(spacing: 20) {
                Image(systemName: didSave ? "checkmark.circle.fill" : "person.crop.rectangle.stack")
                    .font(.system(size: 44))
                    .foregroundColor(didSave ? .green : .accentColor)

                VStack(spacing: 6) {
                    Text(didSave ? "Saved" : "Ready to Export")
                        .font(.title3.bold())
                    Text("\(export.profiles.count) actor\(export.profiles.count == 1 ? "" : "s"), \(export.photos.count) photo\(export.photos.count == 1 ? "" : "s")")
                        .foregroundColor(.secondary)
                }

                if !didSave {
                    Button("Save…") { isShowingSaveSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Actors to Export",
                systemImage: "person.crop.rectangle.stack.slash",
                description: Text("This library has no actor profiles yet.")
            )
        }
    }

    private var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "ViLM Actors \(formatter.string(from: Date())).vilmactors"
    }

    private func buildExport() async {
        do {
            let url = libraryURL
            let result = try await Task.detached(priority: .utility) {
                let store = try LibraryStore(at: url)
                return try store.exportGraph()
            }.value
            await MainActor.run {
                self.export = result.profiles.isEmpty ? nil : result
                self.isBuilding = false
            }
        } catch {
            await MainActor.run {
                self.isBuilding = false
                self.errorMessage = "Failed to build export: \(error.localizedDescription)"
            }
        }
    }
}
