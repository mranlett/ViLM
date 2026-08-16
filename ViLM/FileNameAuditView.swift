// FileNameAuditView.swift
// Settings tool: compares each video's filename against the name the naming
// rules would give it, and batch-renames the mismatches.
//
// 🚨 THE PROPOSALS COME FROM THE PLANNER. This screen used
// `Asset.suggestedFileNameFromTags` — the OLD grammar, `Actors - Series -
// Tags - Studios` — so it listed every video that did not match a scheme the
// app had stopped using, and offered to rename the whole library BACK to it.
// A cleanup tool that undoes the Relocation Plan one batch at a time.
//
// ⚠️ This screen renames IN PLACE and the plan also files into folders, so the
// two are not interchangeable — see the footer. It overlaps the plan enough
// to be worth retiring, but that is the operator's call and not a decision to
// take inside a bug fix.

import SwiftUI
import LibraryCore

struct FileNameAuditView: View {
    @Environment(\.dismiss) private var dismiss
    
    let libraryURL: URL
    let assets: [Asset]
    let onRefresh: () -> Void
    
    /// What the CURRENT rules would call each file, keyed by asset.
    ///
    /// ⭐ One whole-library plan, not one scoped plan per video: the planner
    /// reads every asset and every profile to resolve cast and studio, so
    /// asking it per row would be that work repeated once per file.
    @State private var proposals: [Asset.ID: String] = [:]
    @State private var isLoadingProposals = true

    // Grouped by primary studio, then sorted by series/name
    private var groupedAssets: [(studio: String, items: [Asset])] {
        let mismatches = assets.filter {
            guard let suggested = proposals[$0.id] else { return false }
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
                if isLoadingProposals {
                    ContentUnavailableView(
                        "Working out the names…",
                        systemImage: "hourglass",
                        description: Text("Reading every video's cast and studio to see what it should be called.")
                    )
                } else if groupedAssets.isEmpty {
                    // ⚠️ Distinguishes "nothing to do" from "nothing could be
                    // named": a video the rules refuse to file has no proposal
                    // at all and is silently absent from this list, which is
                    // why the Relocation Plan is named as the place that says
                    // WHY.
                    ContentUnavailableView(
                        "Nothing to rename",
                        systemImage: "checkmark.seal",
                        description: Text("Every file the naming rules can name already has that name. Videos they cannot name are not listed here — the Relocation Plan says why.")
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
                                        
                                        if let suggested = proposals[asset.id] {
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
            .task { await loadProposals() }
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
        .macSheet(minWidth: 500, minHeight: 400)
    }
    
    /// Runs ONE whole-library plan and keeps the file-name half of it.
    ///
    /// ⭐ The plan is the single source of these names. Asking `ContentNaming`
    /// directly would mean assembling a naming context here — a second
    /// expression of studio placement and cast resolution, which is how this
    /// screen and the plan came to disagree in the first place.
    ///
    /// ⚠️ A video the rules REFUSE to file has no proposal and is simply absent
    /// from this list. That is deliberate: this screen renames, and a video
    /// that cannot be named has nothing to rename to. The Relocation Plan is
    /// where the reason is reported.
    private func loadProposals() async {
        let url = libraryURL
        let found = await Task.detached(priority: .userInitiated) { () -> [Asset.ID: String] in
            guard let store = try? LibraryStore(at: url),
                  let plan = try? store.relocationPlan() else { return [:] }
            var byId: [Asset.ID: String] = [:]
            for move in plan.moves {
                byId[move.assetId] = (move.to as NSString).lastPathComponent
            }
            return byId
        }.value
        proposals = found
        isLoadingProposals = false
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
            // 🚨 The HARDENED renamer, not a third hand-rolled copy of "move
            // the file then update the row". The version here moved the file
            // first and updated the catalogue second with NO rollback, so a
            // failed write left the file renamed and the row pointing at a
            // path that no longer existed — the video reads as missing and its
            // metadata is orphaned. `FileRenamerService` exists because that
            // exact defect was fixed once already, and it also carries the
            // duplicate-scan fingerprint across.
            let renamer = FileRenamerService(store: store)
            var failures: [String] = []

            for id in selectedAssetIDs {
                guard var asset = assets.first(where: { $0.id == id }),
                      let suggestedName = proposals[id],
                      suggestedName != asset.fileName else { continue }
                do {
                    try renamer.rename(asset: &asset, newFileName: suggestedName,
                                       libraryURL: libraryURL)
                } catch {
                    // ⚠️ One failure does not abandon the rest. The previous
                    // loop threw out of the whole batch, leaving earlier
                    // renames done, later ones not, and nothing saying which.
                    // A name already taken is the ordinary case here — this
                    // screen has no collision check, which the Relocation Plan
                    // does.
                    failures.append(asset.fileName)
                }
            }

            if !failures.isEmpty {
                errorMessage = failures.count == 1
                    ? "Couldn't rename \(failures[0]) — something is probably already using that name."
                    : "Couldn't rename \(failures.count) files; a name is probably already in use. The rest were renamed."
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
