// SeriesRemovalView.swift
// Removing series names in bulk.
//
// The counterpart to Standardize Series: that one MERGES variants of a name
// worth keeping, this one takes names off videos entirely. Both exist because
// series is free text with no node behind it, so a bad match writes into the
// same column the operator uses to organise a collection by hand.
//
// ⚠️ Destructive and not undoable from inside the app, so the screen is built
// to make keeping easy and removing deliberate: nothing is pre-selected, the
// most-used names lead, and the count of affected videos is stated on the
// button rather than discovered afterwards.

import SwiftUI
import LibraryCore

struct SeriesRemovalView: View {
    let libraryURL: URL
    let assets: [Asset]
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var usage: [SeriesNameUsage] = []
    @State private var selected: Set<String> = []
    @State private var clearsEpisodeInfo = false
    @State private var searchText = ""
    @State private var isWorking = false
    @State private var summary: String?
    @State private var failure: String?

    private var visible: [SeriesNameUsage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return usage }
        return usage.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var affectedCount: Int {
        usage.filter { selected.contains($0.name) }.reduce(0) { $0 + $1.videoCount }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Remove Series Names")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onFinish(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if summary == nil {
                            Button("Remove \(affectedCount)", role: .destructive) {
                                Task { await apply() }
                            }
                            .disabled(selected.isEmpty || isWorking)
                        }
                    }
                }
        }
        .macSheet(minWidth: 720, minHeight: 600)
        .task { usage = SeriesNameAudit.usage(in: assets) }
    }

    @ViewBuilder
    private var content: some View {
        if let summary {
            ContentUnavailableView("Done", systemImage: "checkmark.circle",
                                   description: Text(summary))
        } else if let failure {
            ContentUnavailableView("Couldn't remove those", systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if usage.isEmpty {
            ContentUnavailableView("No series names",
                                   systemImage: "rectangle.stack",
                                   description: Text("No video in this library carries a series name."))
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Toggle("Also clear season, episode number and episode title",
                       isOn: $clearsEpisodeInfo)
            } footer: {
                // ⚠️ Off by default, and the reason is the operator's own case:
                // a series name set by hand exists SO the episode numbers sort.
                // Taking the numbering out as a side effect of removing a name
                // would destroy the more valuable half of the record.
                Text(clearsEpisodeInfo
                     ? "Episode numbering will be removed too. Use this when a bad match wrote the whole block and all of it is wrong."
                     : "Only the series name is removed. Episode numbers you set yourself are kept.")
            }

            if usage.contains(where: \.isSingleUse) {
                Section {
                    Button {
                        selectSingleUse()
                    } label: {
                        Label("Select the \(usage.filter(\.isSingleUse).count) used by one video",
                              systemImage: "1.circle")
                    }
                    if !selected.isEmpty {
                        Button("Clear selection") { selected.removeAll() }
                    }
                } footer: {
                    Text("A series exists to group videos, so a name used by exactly one is usually a title that arrived with a match rather than a series you created. Worth checking before removing — this is a shortcut, not a verdict.")
                }
            }

            Section {
                ForEach(visible) { entry in
                    Button { toggle(entry.name) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(entry.name)
                                  ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(entry.name)
                                                 ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.body)
                                Text(subtitle(for: entry))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(usage.count) series names")
            } footer: {
                Text("Nothing is selected to begin with, and nothing is removed until you press Remove.")
            }
        }
        .searchable(text: $searchText, prompt: "Find a series name")
    }

    /// Counts plus the one hint available about where a name came from.
    ///
    /// ⚠️ Worded as a hint. Nothing records who wrote a series name — a video
    /// the operator named and later matched counts as matched here — so this
    /// says "worth looking at", never "this came from the source".
    private func subtitle(for entry: SeriesNameUsage) -> String {
        var parts = ["\(entry.videoCount) video\(entry.videoCount == 1 ? "" : "s")"]
        if entry.matchedCount > 0 {
            parts.append("\(entry.matchedCount) matched to a source")
        }
        return parts.joined(separator: " · ")
    }

    private func toggle(_ name: String) {
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
    }

    private func selectSingleUse() {
        selected.formUnion(usage.filter(\.isSingleUse).map(\.name))
    }

    private func apply() async {
        isWorking = true
        failure = nil
        let names = selected
        let clearsEpisodes = clearsEpisodeInfo
        let url = libraryURL
        let source = assets

        let result: Result<Int, Error> = await Task.detached {
            do {
                let store = try LibraryStore(at: url)
                let affected = SeriesNameAudit.affectedAssets(in: source, clearing: names)
                for asset in affected {
                    try store.updateAsset(
                        SeriesNameAudit.cleared(asset, includingEpisodeInfo: clearsEpisodes))
                }
                return .success(affected.count)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case let .success(count):
            summary = "Removed \(names.count) series name\(names.count == 1 ? "" : "s") from \(count) video\(count == 1 ? "" : "s")."
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"),
                                            object: nil)
        case let .failure(error):
            failure = error.localizedDescription
        }
        isWorking = false
    }
}
