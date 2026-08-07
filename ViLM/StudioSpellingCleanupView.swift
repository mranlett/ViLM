// StudioSpellingCleanupView.swift
// Merging studios stored under two spellings.
//
// 🚨 Exists because Studio Health used to route these to *Repair Tag Spelling*,
// which reads `Asset.actions` — `tag:` values only. It never sees a `studio:`
// value, so it could not have fixed a single one of them. Reported from the
// device, 2026-08-06.
//
// Deliberately the same shape as the tag version: nothing pre-selected, the
// keeper stated per row and changeable, the affected count on the button.

import SwiftUI
import LibraryCore

struct StudioSpellingCleanupView: View {
    let libraryURL: URL
    let assets: [Asset]
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var collisions: [StudioSpellingCollision] = []
    /// Keeper per collision, defaulting to the suggestion and overridable.
    @State private var keepers: [String: String] = [:]
    @State private var accepted: Set<String> = []
    @State private var isApplying = false
    @State private var summary: String?

    private var affectedVideos: Int {
        collisions.filter { accepted.contains($0.key) }
            .reduce(0) { total, collision in
                let keeper = keepers[collision.key] ?? collision.suggestedKeeper
                return total + collision.spellings
                    .filter { $0.spelling != keeper }
                    .reduce(0) { $0 + $1.uses }
            }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Studio Spelling")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onFinish(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if summary == nil && !collisions.isEmpty {
                            Button("Merge \(affectedVideos)") { Task { await apply() } }
                                .disabled(accepted.isEmpty || isApplying)
                        }
                    }
                }
        }
        .macSheet(minWidth: 700, minHeight: 560)
        .task { reload() }
    }

    @ViewBuilder
    private var content: some View {
        if let summary {
            ContentUnavailableView("Done", systemImage: "checkmark.circle",
                                   description: Text(summary))
        } else if collisions.isEmpty {
            ContentUnavailableView("Every studio is spelled one way",
                                   systemImage: "checkmark.seal",
                                   description: Text("No two studios differ only by case or spacing."))
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(collisions) { collision in
                let keeper = keepers[collision.key] ?? collision.suggestedKeeper
                Section {
                    ForEach(collision.spellings, id: \.spelling) { entry in
                        Button {
                            keepers[collision.key] = entry.spelling
                            accepted.insert(collision.key)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.spelling == keeper
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(entry.spelling == keeper
                                                     ? Color.accentColor : .secondary)
                                Text(entry.spelling)
                                Spacer()
                                Text("\(entry.uses)")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Toggle("Merge into “\(keeper)”", isOn: Binding(
                        get: { accepted.contains(collision.key) },
                        set: { on in
                            if on { accepted.insert(collision.key) }
                            else { accepted.remove(collision.key) }
                        }))
                } footer: {
                    // States the direction, because a merge is destructive to
                    // the losing spelling and the row above only shows a dot.
                    Text(collision.losers.isEmpty
                         ? "Pick the spelling to keep."
                         : "\(collision.losers.joined(separator: ", ")) → \(keeper)")
                }
            }
        }
    }

    private func reload() {
        collisions = StudioSpellingAudit.collisions(in: assets)
        keepers = Dictionary(uniqueKeysWithValues:
            collisions.map { ($0.key, $0.suggestedKeeper) })
        accepted = []
    }

    private func apply() async {
        isApplying = true
        var merged = 0
        do {
            let store = try LibraryStore(at: libraryURL)
            for collision in collisions where accepted.contains(collision.key) {
                let keeper = keepers[collision.key] ?? collision.suggestedKeeper
                for loser in collision.spellings.map(\.spelling) where loser != keeper {
                    // The same global rename the studio profile page uses, with
                    // the `studio:` prefix — which is exactly what makes this
                    // work where the tag tool could not.
                    try store.renameTagGlobally(oldTag: "studio:\(loser)",
                                                newTag: "studio:\(keeper)")
                    merged += 1
                }
            }
            summary = "Merged \(merged) spelling\(merged == 1 ? "" : "s")."
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"),
                                            object: nil)
        } catch {
            AppErrorReporter.report("Couldn't merge those studios: \(error.localizedDescription)")
        }
        isApplying = false
    }
}
