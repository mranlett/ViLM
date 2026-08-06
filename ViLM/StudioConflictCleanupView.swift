// StudioConflictCleanupView.swift
// Resolves videos that ended up with more than one studio.
//
// Grouped by the pairing rather than listed per video: one bad match or one
// enrichment run that added instead of replacing produces the identical pair
// everywhere it touched, so a single choice usually fixes dozens of records.
//
// Nothing is pre-selected beyond the keeper. Discarding a studio is
// destructive, and the evidence behind the suggestion — how often each stands
// alone elsewhere — is shown so it can be overruled rather than trusted.

import SwiftUI
import LibraryCore

struct StudioConflictCleanupView: View {
    let libraryURLs: [URL]
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var conflicts: [StudioConflict] = []
    @State private var owner: [UUID: URL] = [:]
    @State private var keepers: [String: String] = [:]
    @State private var accepted: Set<String> = []
    @State private var isWorking = true
    @State private var summary: String?

    private var selectedVideos: Int {
        conflicts.filter { accepted.contains($0.id) }.reduce(0) { $0 + $1.videoCount }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Duplicate Studios")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onFinish(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !conflicts.isEmpty {
                            Button("Fix \(selectedVideos)") { Task { await apply() } }
                                .disabled(accepted.isEmpty || isWorking)
                        }
                    }
                }
        }
        .macSheet(minWidth: 700, minHeight: 540)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView()
        } else if let summary {
            ContentUnavailableView("Done", systemImage: "checkmark.circle",
                                   description: Text(summary))
        } else if conflicts.isEmpty {
            ContentUnavailableView(
                "No duplicate studios", systemImage: "checkmark.circle",
                description: Text("Every video carries at most one studio."))
        } else {
            List {
                Section {
                    ForEach(conflicts) { conflict in
                        row(conflict)
                    }
                } header: {
                    Text("\(conflicts.count) pairing\(conflicts.count == 1 ? "" : "s"), \(conflicts.reduce(0) { $0 + $1.videoCount }) videos")
                } footer: {
                    Text("A scene has one releasing studio, so these are certainly wrong. The suggested keeper is whichever is used on its own most often elsewhere — check it, because that is evidence rather than proof.")
                }
            }
        }
    }

    private func row(_ conflict: StudioConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    toggle(conflict.id)
                } label: {
                    Image(systemName: accepted.contains(conflict.id)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(accepted.contains(conflict.id)
                                         ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                Text("\(conflict.videoCount) video\(conflict.videoCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            // Which one survives, with the evidence next to it.
            Picker("Keep", selection: Binding(
                get: { keepers[conflict.id] ?? conflict.suggestedKeeper },
                set: { keepers[conflict.id] = $0 }
            )) {
                ForEach(conflict.studios, id: \.self) { studio in
                    let solo = conflict.soloUseElsewhere[studio] ?? 0
                    Text("\(studio)  ·  \(solo) alone").tag(studio)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func toggle(_ id: String) {
        if accepted.contains(id) { accepted.remove(id) } else { accepted.insert(id) }
    }

    private func scan() async {
        isWorking = true
        summary = nil
        var all: [Asset] = []
        var ownership: [UUID: URL] = [:]
        for url in libraryURLs {
            guard let assets = try? LibraryStore(at: url).fetchAllAssets() else { continue }
            for asset in assets { ownership[asset.id] = url }
            all += assets
        }
        owner = ownership
        conflicts = StudioConflictAudit.conflicts(in: all)
        // Pre-ticked: the state is certainly wrong, so the only real question is
        // which studio survives — and that is answered by the picker.
        accepted = Set(conflicts.map(\.id))
        isWorking = false
    }

    private func apply() async {
        isWorking = true
        var fixed = 0
        var byId: [UUID: Asset] = [:]
        var stores: [URL: LibraryStore] = [:]
        for url in libraryURLs {
            guard let store = try? LibraryStore(at: url) else { continue }
            stores[url] = store
            for asset in (try? store.fetchAllAssets()) ?? [] { byId[asset.id] = asset }
        }

        for conflict in conflicts where accepted.contains(conflict.id) {
            let keeper = keepers[conflict.id] ?? conflict.suggestedKeeper
            for id in conflict.assetIds {
                guard let asset = byId[id], let url = owner[id], let store = stores[url] else { continue }
                do {
                    try store.updateAsset(StudioConflictAudit.resolving(asset, keeping: keeper))
                    fixed += 1
                } catch {
                    AppErrorReporter.report(
                        "Couldn't fix \(asset.fileName): \(error.localizedDescription)")
                }
            }
        }
        summary = "Fixed \(fixed) video\(fixed == 1 ? "" : "s")."
        conflicts = []
        accepted = []
        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        isWorking = false
    }
}
