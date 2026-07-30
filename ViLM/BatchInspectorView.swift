// BatchInspectorView.swift
// Bulk video editing for a multi-selection: toggle reviewed status, add or
// remove shared tags, and set Series Name/Season across all selected videos.

import SwiftUI
import LibraryCore

struct BatchInspectorView: View {
    let selectedAssetIDs: Set<Asset.ID>
    @Binding var assets: [Asset]
    let libraryURL: URL?
    
    @State private var isShowingTagEntry = false
    @State private var newTagValue = ""
    @State private var activeCategory = "tag"

    @State private var batchSeriesName = ""
    @State private var batchSeason = ""

    private var selectedAssets: [Asset] {
        assets.filter { selectedAssetIDs.contains($0.id) }
    }

    // Prefill values shared by every selected video, else empty/nil.
    private var commonVideoName: String? {
        let first = selectedAssets.first?.videoName
        return selectedAssets.allSatisfy { $0.videoName == first } ? first : nil
    }

    private var commonSeason: Int? {
        let first = selectedAssets.first?.seasonNumber
        return selectedAssets.allSatisfy { $0.seasonNumber == first } ? first : nil
    }
    
    private var commonStudios: [String] {
        commonTags(prefix: "studio:")
    }
    
    private var commonActors: [String] {
        commonTags(prefix: "actor:")
    }
    
    private var commonActions: [String] {
        commonTags(prefix: "tag:")
    }
    
    private func commonTags(prefix: String) -> [String] {
        guard !selectedAssets.isEmpty else { return [] }
        var common = Set(selectedAssets[0].tags.filter { $0.hasPrefix(prefix) })
        for asset in selectedAssets.dropFirst() {
            common.formIntersection(asset.tags.filter { $0.hasPrefix(prefix) })
        }
        return common.map { String($0.dropFirst(prefix.count)) }.sorted()
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Batch Edit Mode")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("\(selectedAssetIDs.count) assets selected")
                    .foregroundColor(.secondary)
                
                Divider()
                
                Button(action: toggleStatus) {
                    Label("Toggle Reviewed Status for All", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.bordered)

                Divider()

                seriesSection

                Divider()

                Text("Shared Tags")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                tagSection(title: "Studios", items: commonStudios, category: "studio", color: .purple)
                Divider()
                tagSection(title: "Actors", items: commonActors, category: "actor", color: .blue)
                Divider()
                tagSection(title: "Tags", items: commonActions, category: "tag", color: .green)
                
                Color.clear.frame(height: 40)
            }
            .padding()
        }
        .frame(minWidth: 300)
        .popover(isPresented: $isShowingTagEntry) {
            tagEntryPopover
        }
        .onAppear {
            batchSeriesName = commonVideoName ?? ""
            batchSeason = commonSeason.map(String.init) ?? ""
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Series").font(.headline).foregroundColor(.secondary)

            Text("Series Name").font(.subheadline).foregroundColor(.secondary)
            HStack {
                TextField("Series name for all", text: $batchSeriesName)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") { applySeriesName() }
                    .buttonStyle(.bordered)
            }

            Text("Season / Movie #").font(.subheadline).foregroundColor(.secondary)
            HStack {
                TextField("Season for all", text: $batchSeason)
                    .textFieldStyle(.roundedBorder)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                Button("Apply") { applySeason() }
                    .buttonStyle(.bordered)
            }

            Text("Applies to all \(selectedAssetIDs.count) selected videos. Episode number and title are edited per-video.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func applySeriesName() {
        let name = TagNormalizer.titleCased(batchSeriesName)
        applyToAll { $0.videoName = name.isEmpty ? nil : name }
    }

    private func applySeason() {
        let season = Int(batchSeason.trimmingCharacters(in: .whitespaces))
        applyToAll { $0.seasonNumber = season }
    }

    private func applyToAll(_ mutate: (inout Asset) -> Void) {
        do {
            // A batch can span libraries in a federated session — resolve the
            // store per asset, not once for the whole batch.
            for var asset in selectedAssets {
                mutate(&asset)
                try LibrarySession.shared.store(for: asset.id).updateAsset(asset)
                if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                    assets[index] = asset
                }
            }
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch {
            print("Batch series update failed: \(error)")
            AppErrorReporter.report("Couldn't apply the series changes: \(error.localizedDescription)")
        }
    }
    
    private func tagSection(title: String, items: [String], category: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.bold)
                Spacer()
                Button {
                    activeCategory = category
                    newTagValue = ""
                    isShowingTagEntry = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(color)
            }
            
            if items.isEmpty {
                Text("None").font(.caption).foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        TagBubble(label: item, color: color, onEdit: {
                            // no edit in batch mode
                        }) {
                            deleteTag(category: category, value: item)
                        }
                    }
                }
            }
        }
    }
    
    private var allLibraryTagValues: Set<String> {
        var tags = Set<String>()
        for a in assets {
            for t in a.tags {
                let parts = t.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    tags.insert(String(parts[1]))
                } else {
                    tags.insert(t)
                }
            }
        }
        return tags
    }
    
    private var tagEntryPopover: some View {
        VStack(spacing: 12) {
            Text("Add to All \(activeCategory.capitalized)")
                .font(.headline)
            TextField("Name...", text: $newTagValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTag() }
                
            if !newTagValue.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        let matches = allLibraryTagValues.filter { $0.localizedCaseInsensitiveContains(newTagValue) && $0 != newTagValue }.sorted()
                        
                        ForEach(matches, id: \.self) { match in
                            Text(match)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    newTagValue = match
                                }
                            Divider()
                        }
                    }
                }
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .frame(maxHeight: 150)
            }
                
            Button("Save") { saveTag() }
                .buttonStyle(.borderedProminent)
                
        }
        .padding()
        .frame(minWidth: 200, maxWidth: 300)
    }
    
    private func toggleStatus() {
        do {
            let allReviewed = selectedAssets.allSatisfy { $0.status == .reviewed }
            let newStatus: Asset.ReviewStatus = allReviewed ? .unreviewed : .reviewed

            for var asset in selectedAssets {
                asset.status = newStatus
                try LibrarySession.shared.store(for: asset.id).updateAsset(asset)
                if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                    assets[index] = asset
                }
            }
        } catch {
            print("Batch update failed: \(error)")
            AppErrorReporter.report("Couldn't apply the batch changes: \(error.localizedDescription)")
        }
    }
    
    private func saveTag() {
        guard !newTagValue.isEmpty else { return }
        do {
            let normalizedValue = TagNormalizer.normalize(tagValue: newTagValue)
            let tagToSave = "\(activeCategory):\(normalizedValue)"

            for var asset in selectedAssets {
                if !asset.tags.contains(tagToSave) {
                    asset.tags.append(tagToSave)
                    try LibrarySession.shared.store(for: asset.id).updateAsset(asset)
                    if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                        assets[index] = asset
                    }
                }
            }
        } catch {
            print("Batch tag failed: \(error)")
            AppErrorReporter.report("Couldn't add the tag to the selected videos: \(error.localizedDescription)")
        }
        newTagValue = ""
        isShowingTagEntry = false
    }
    
    private func deleteTag(category: String, value: String) {
        do {
            let tagToDelete = "\(category):\(value)"

            for var asset in selectedAssets {
                if asset.tags.contains(tagToDelete) {
                    asset.tags.removeAll { $0 == tagToDelete }
                    try LibrarySession.shared.store(for: asset.id).updateAsset(asset)
                    if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                        assets[index] = asset
                    }
                }
            }
        } catch {
            print("Batch tag delete failed: \(error)")
            AppErrorReporter.report("Couldn't remove the tag from the selected videos: \(error.localizedDescription)")
        }
    }
}
