// FileNameAuditView.swift
// Settings tool: compares each video's filename against the name its metadata
// suggests (suggestedFileNameFromTags) and batch-renames the mismatches.

import SwiftUI
import LibraryCore

struct FileNameAuditView: View {
    @Environment(\.dismiss) private var dismiss
    
    let libraryURL: URL
    let assets: [Asset]
    let onRefresh: () -> Void
    
    // Grouped by primary studio, then sorted by series/name
    private var groupedAssets: [(studio: String, items: [Asset])] {
        let mismatches = assets.filter {
            guard let suggested = $0.suggestedFileNameFromTags else { return false }
            return suggested != $0.fileName
        }
        
        let grouped = Dictionary(grouping: mismatches) { $0.studios.first ?? "No Studio" }
        
        return grouped.map { (studio: $0.key, items: $0.value.sorted { $0.fileName < $1.fileName }) }
            .sorted { $0.studio < $1.studio }
    }
    
    @State private var selectedAssetIDs: Set<Asset.ID> = []
    @State private var isRenaming = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationStack {
            List {
                if groupedAssets.isEmpty {
                    ContentUnavailableView(
                        "All Good!",
                        systemImage: "checkmark.seal",
                        description: Text("All files match their suggested metadata names.")
                    )
                } else {
                    ForEach(groupedAssets, id: \.studio) { group in
                        Section(header: Text(group.studio)) {
                            ForEach(group.items) { asset in
                                HStack {
                                    Image(systemName: selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedAssetIDs.contains(asset.id) ? .blue : .secondary)
                                        .onTapGesture {
                                            toggleSelection(asset.id)
                                        }
                                    
                                    VStack(alignment: .leading) {
                                        Text(asset.fileName)
                                            .font(.caption)
                                            .strikethrough()
                                            .foregroundColor(.secondary)
                                        
                                        if let suggested = asset.suggestedFileNameFromTags {
                                            Text(suggested)
                                                .font(.callout)
                                                .foregroundColor(.primary)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    toggleSelection(asset.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("File Name Audit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename Selected (\(selectedAssetIDs.count))") {
                        Task { await performRename() }
                    }
                    .disabled(selectedAssetIDs.isEmpty || isRenaming)
                }
            }
            .overlay {
                if isRenaming {
                    ProgressView("Renaming...")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(10)
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
    
    private func toggleSelection(_ id: Asset.ID) {
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
    }
    
    private func performRename() async {
        isRenaming = true
        defer { isRenaming = false }
        
        do {
            let store = try LibraryStore(at: libraryURL)
            let fileManager = FileManager.default
            
            for id in selectedAssetIDs {
                guard var asset = assets.first(where: { $0.id == id }),
                      let suggestedName = asset.suggestedFileNameFromTags else { continue }
                
                let oldURL = libraryURL.appendingPathComponent(asset.relativePath)
                let oldDir = oldURL.deletingLastPathComponent()
                let newURL = oldDir.appendingPathComponent(suggestedName)
                
                // Determine new relative path
                let libraryPath = libraryURL.standardizedFileURL.path
                let newFilePath = newURL.standardizedFileURL.path
                let newRelativePath: String
                
                if newFilePath.hasPrefix(libraryPath) {
                    var rel = String(newFilePath.dropFirst(libraryPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    newRelativePath = rel
                } else {
                    newRelativePath = newURL.lastPathComponent
                }
                
                // Move file on disk
                if fileManager.fileExists(atPath: oldURL.path) {
                    try fileManager.moveItem(at: oldURL, to: newURL)
                    
                    // Update asset and save to DB
                    asset.fileName = suggestedName
                    asset.relativePath = newRelativePath
                    try store.updateAsset(asset)
                }
            }
            
            // Clean up selections and refresh UI
            selectedAssetIDs.removeAll()
            await MainActor.run {
                onRefresh()
            }
            
        } catch {
            errorMessage = "Failed to rename files: \(error.localizedDescription)"
        }
    }
}
