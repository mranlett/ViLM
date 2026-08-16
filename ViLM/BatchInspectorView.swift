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

    /// Set when a bulk declaration was refused because part of the selection
    /// already answered. Holds what was asked for, so the offer can repeat it.
    @State private var pendingOverwrite: (kind: ContentKind, count: Int)?
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

                contentKindSection
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

    /// Declaring what these videos ARE — the bulk surface the privacy boundary
    /// depends on (#59).
    ///
    /// 🚨 Every row starts undeclared and undeclared content is refused, so
    /// without a way to declare in bulk the boundary would simply halt a
    /// 2,000-video library. This is that way: select all, declare, then pick
    /// out the exceptions.
    ///
    /// ⚠️ Nothing is pre-selected. A default kind would be inference wearing a
    /// declaration's clothes, and `personal` is the case where being wrong
    /// cannot be taken back.
    private var contentKindSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are these?").font(.headline).foregroundColor(.secondary)

            HStack {
                ForEach(ContentKind.allCases, id: \.self) { kind in
                    Button(kind.displayName) { applyContentKind(kind) }
                        .buttonStyle(.bordered)
                }
            }

            // ⚠️ The refusal is an OFFER, not a dead end. Refusing outright made
            // a wrong bulk declaration correctable only one video at a time,
            // which across a whole library is no correction at all.
            if let pending = pendingOverwrite {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(pending.count) of \(selectedAssets.count) already say what they are.")
                        .font(.caption)
                    // 🚨 The button names the number it ACTS ON — the whole
                    // selection — not the number that triggered the refusal.
                    //
                    // It used to say "Change all \(pending.count)", which is the
                    // already-declared count: with 50 selected and 1 declared it
                    // read "Change all 1 to Scene" and then changed all 50. A
                    // number the operator approves has to be the number that
                    // happens, or the confirmation is worse than none.
                    Button("Change all \(selectedAssets.count) to \(pending.kind.displayName)") {
                        applyContentKind(pending.kind, overwriting: true)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Videos marked Personal are never changed this way — open those "
                         + "individually.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            // ⭐ Says what each kind MEANS, not just what it protects. The kind
            // picks the filing grammar, so this is the decision that determines
            // where the file ends up on disk — and the privacy line alone left
            // that invisible.
            VStack(alignment: .leading, spacing: 3) {
                Text("Scene — filed under its studio, named with the performers and date.")
                Text("Film — its own folder, named with the title and year.")
                Text("Episodic — filed under its series and season.")
                Text("Personal — kept separate, and never sent anywhere.")
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            Text("Titles are only sent to an external source once you say a video is not "
                 + "your own. Personal videos are never sent — and neither is anything "
                 + "still undeclared.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// ⚠️ NOT `applyToAll`. That writes row by row, so a mid-batch failure
    /// leaves a half-declared selection that looks exactly like a finished one.
    /// T25 requires all or nothing, and it also requires refusing a selection
    /// that is already declared — re-declaring in bulk is how a video marked
    /// `personal` would silently become `scene`.
    private func applyContentKind(_ kind: ContentKind, overwriting: Bool = false) {
        pendingOverwrite = nil
        let ids = selectedAssets.map(\.id)
        // Grouped by store: a federated selection can span libraries, and one
        // transaction cannot cross two databases.
        var byStore: [ObjectIdentifier: (LibraryStore, [UUID])] = [:]
        for id in ids {
            guard let store = try? LibrarySession.shared.store(for: id) else { continue }
            let key = ObjectIdentifier(store)
            byStore[key, default: (store, [])].1.append(id)
        }
        do {
            for (store, group) in byStore.values {
                try store.declareContentKind(kind, forAssetIds: group,
                                             overwritingExisting: overwriting)
            }
            for index in assets.indices where ids.contains(assets[index].id) {
                assets[index].contentKind = kind
            }
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch let refusal as DeclarationRefusal {
            // An already-declared selection becomes an offer; everything else
            // is reported and stops there.
            if case let .alreadyDeclared(count) = refusal {
                pendingOverwrite = (kind: kind, count: count)
            } else {
                AppErrorReporter.report(refusal.reason)
            }
        } catch {
            AppErrorReporter.report("Couldn't declare those: \(error.localizedDescription)")
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
