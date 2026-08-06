// TagCaseCleanupView.swift
// Repairs tag capitalization, and merges tags stored under more than one.
//
// Safe to run repeatedly: it reads the library each time, proposes only what is
// still wrong, and does nothing without being told to. A run that finds nothing
// says so rather than presenting an empty list that looks broken.
//
// The two halves are separated because their certainty differs.
//
//   Duplicates are a fact — the filters already treat these as one tag, so two
//   rows for it is just a split record. Pre-ticked.
//
//   Respellings are a suggestion from whatever source is installed. That source
//   is authoritative about its own vocabulary and nothing else, so nothing here
//   is ticked by default and the current spelling is always shown beside it.
//
// No vocabulary is built in. Canonical spellings are asked of the source at run
// time, which is why this can improve without the app changing.

import SwiftUI
import LibraryCore

struct TagCaseCleanupView: View {
    let libraryURL: URL
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var collisions: [TagCaseCollision] = []
    @State private var respellings: [TagRespelling] = []
    @State private var tagCount = 0
    @State private var isScanning = false
    @State private var isApplying = false
    @State private var progress = ""
    @State private var summary: String?

    @State private var acceptedMerges: Set<String> = []
    @State private var acceptedRespellings: Set<String> = []

    private var provider: (any VideoMetadataProvider)? {
        PluginEnvironment.registry.installedVideoProviders().first
    }

    private var totalSelected: Int { acceptedMerges.count + acceptedRespellings.count }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Tag Spelling")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onFinish(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !collisions.isEmpty || !respellings.isEmpty {
                            Button(isApplying ? "Applying…" : "Apply \(totalSelected)") {
                                Task { await apply() }
                            }
                            .disabled(totalSelected == 0 || isApplying)
                        }
                    }
                }
        }
        .macSheet(minWidth: 700, minHeight: 540)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isScanning || isApplying {
            VStack(spacing: 10) {
                ProgressView()
                Text(progress.isEmpty ? "Reading tags…" : progress)
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let summary {
            ContentUnavailableView {
                Label("Done", systemImage: "checkmark.circle")
            } description: {
                Text(summary)
            } actions: {
                Button("Scan again") { Task { await scan() } }
            }
        } else if collisions.isEmpty && respellings.isEmpty {
            ContentUnavailableView(
                "Nothing to repair",
                systemImage: "checkmark.circle",
                description: Text("All \(tagCount) tags are spelled consistently."
                                  + (provider == nil
                                     ? " Install a metadata source to also check them against its vocabulary."
                                     : "")))
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !collisions.isEmpty {
                Section {
                    ForEach(collisions) { collision in
                        mergeRow(collision)
                    }
                } header: {
                    Text("Stored under more than one spelling — \(collisions.count)")
                } footer: {
                    Text("These are already the same tag everywhere it matters, so merging loses nothing. The most-used spelling is kept.")
                }
            }

            if !respellings.isEmpty {
                Section {
                    ForEach(respellings) { respelling in
                        respellRow(respelling)
                    }
                } header: {
                    Text("Spelled differently by the source — \(respellings.count)")
                } footer: {
                    Text("Suggestions only, and only where the letters match and the capitals differ. Nothing here is ticked for you.")
                }
            }
        }
    }

    private func mergeRow(_ collision: TagCaseCollision) -> some View {
        Button {
            toggle(&acceptedMerges, collision.key)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                tick(acceptedMerges.contains(collision.key))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(collision.suggestedKeeper).fontWeight(.medium)
                        Text("keep").font(.caption2).foregroundStyle(.green)
                    }
                    ForEach(collision.losers, id: \.self) { loser in
                        let uses = collision.spellings.first { $0.spelling == loser }?.uses ?? 0
                        Text("\(loser) — \(uses) video\(uses == 1 ? "" : "s") move across")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func respellRow(_ respelling: TagRespelling) -> some View {
        Button {
            toggle(&acceptedRespellings, respelling.current)
        } label: {
            HStack(spacing: 10) {
                tick(acceptedRespellings.contains(respelling.current))
                Text(respelling.current).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(respelling.suggested).fontWeight(.medium)
                Spacer()
                Text("\(respelling.uses)").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tick(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
    }

    private func toggle(_ set: inout Set<String>, _ key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }

    // MARK: - Work

    private func scan() async {
        isScanning = true
        summary = nil
        progress = "Reading tags…"
        do {
            let store = try LibraryStore(at: libraryURL)
            let assets = try store.fetchAllAssets()
            let counts = TagCaseAudit.tagCounts(in: assets)
            tagCount = counts.count

            let found = TagCaseAudit.collisions(in: counts)

            // Ask the source how it spells each tag. One request per distinct
            // tag, rate-limited — with a vocabulary this size that is seconds,
            // and it is why no spellings need to be baked into the app.
            var canonical: [String: String] = [:]
            if let provider {
                let delay = UInt64((1.0 / max(provider.requestsPerSecond, 0.1)) * 1_000_000_000)
                for (index, tag) in counts.keys.sorted().enumerated() {
                    progress = "Checking spellings — \(index + 1) of \(counts.count)"
                    if let match = try? await provider.suggestions(for: .tag, matching: tag),
                       let exact = match.first(where: { $0.lowercased() == tag.lowercased() }) {
                        canonical[tag.lowercased()] = exact
                    }
                    try? await Task.sleep(nanoseconds: delay)
                }
            }

            collisions = found
            respellings = TagCaseAudit.respellings(current: counts, canonical: canonical)
            // Duplicates are certain; respellings are a suggestion.
            acceptedMerges = Set(found.map(\.key))
            acceptedRespellings = []
        } catch {
            AppErrorReporter.report("Couldn't read the tags: \(error.localizedDescription)")
        }
        progress = ""
        isScanning = false
    }

    private func apply() async {
        isApplying = true
        var renamed = 0
        do {
            let store = try LibraryStore(at: libraryURL)

            // Merges first. Renaming a loser onto the keeper is exactly the
            // existing global rename, which already moves every video across.
            for collision in collisions where acceptedMerges.contains(collision.key) {
                for loser in collision.losers {
                    progress = "Merging \(loser)…"
                    try store.renameTagGlobally(oldTag: "tag:\(loser)",
                                                newTag: "tag:\(collision.suggestedKeeper)")
                    renamed += 1
                }
            }

            for respelling in respellings where acceptedRespellings.contains(respelling.current) {
                progress = "Respelling \(respelling.current)…"
                try store.renameTagGlobally(oldTag: "tag:\(respelling.current)",
                                            newTag: "tag:\(respelling.suggested)")
                renamed += 1
            }

            summary = "Repaired \(renamed) tag\(renamed == 1 ? "" : "s")."
            collisions = []
            respellings = []
            acceptedMerges = []
            acceptedRespellings = []
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch {
            AppErrorReporter.report("Couldn't repair tags: \(error.localizedDescription)")
        }
        progress = ""
        isApplying = false
    }
}
