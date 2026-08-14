// TagRelationshipsView.swift
// What the tag vocabulary implies about itself.
//
// ⭐ The graph spike asked for this by name: "tags that nearly always travel
// together are either duplicates awaiting a merge or a parent and child
// awaiting a hierarchy that does not exist yet. This is the evidence that would
// justify building tag parentage."
//
// 🚨 So this screen exists to produce EVIDENCE, not to act. It reports and
// repairs nothing, like Impossible Data and unlike Studio Health — whether a
// broad tag is genuinely the parent of a narrow one is a judgement about
// meaning, and co-occurrence cannot make it. Two tags travel together for
// reasons the numbers cannot see: a small library, or one operator's habit.
//
// ⚠️ The two findings are deliberately kept apart on screen. A hierarchy and a
// merge call for opposite actions — keep both tags, or lose one — and a single
// list headed "related tags" would invite the wrong one half the time.

import SwiftUI
import LibraryCore

struct TagRelationshipsView: View {
    let libraryURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var report: TagAffinityReport?
    @State private var names: [String: String] = [:]
    @State private var isWorking = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Tag Relationships")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Re-check") { Task { await scan() } }
                            .disabled(isWorking)
                    }
                }
        }
        .macSheet(minWidth: 720, minHeight: 580)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Comparing how your tags travel…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if let report {
            if report.isEmpty {
                ContentUnavailableView {
                    Label("Your tags stand on their own", systemImage: "checkmark.seal")
                } description: {
                    // ⚠️ Says what was examined. "Nothing found" over an
                    // unstated sample reads as a broken screen.
                    Text("Across \(report.tagsConsidered) tags in use, none is almost always accompanied by another, and no two are used interchangeably. Nothing here suggests a tag should be merged away or filed under a broader one.")
                }
            } else {
                findings(report)
            }
        }
    }

    private func findings(_ report: TagAffinityReport) -> some View {
        List {
            if !report.merges.isEmpty {
                Section {
                    ForEach(report.merges) { row(for: $0, kind: .merge) }
                } header: {
                    header("Possibly two names for one thing",
                           count: report.merges.count,
                           icon: "arrow.triangle.merge", tint: .orange)
                } footer: {
                    Text("Each of these is nearly always used with the other, in both directions — which usually means one idea picked up two names. Merging is a decision only you can make, and nothing here does it.")
                }
            }

            if !report.containment.isEmpty {
                Section {
                    ForEach(report.containment) { row(for: $0, kind: .containment) }
                } header: {
                    header("Narrower tags inside a broader one",
                           count: report.containment.count,
                           icon: "arrow.down.right.and.arrow.up.left", tint: .accentColor)
                } footer: {
                    Text("The first tag almost never appears without the second, while the second appears freely without the first — the shape of a specific thing inside a general one. Tags have no hierarchy yet; this is the evidence for whether one is worth building.")
                }
            }

            Section {
                Text("Examined \(report.tagsConsidered) tags that are actually in use. Pairs sharing fewer than 10 videos are ignored — two tags on two videos are “always together” and mean nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private enum FindingKind { case merge, containment }

    private func row(for finding: TagAffinity, kind: FindingKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name(finding.tag)).font(.callout.weight(.medium))
                Image(systemName: kind == .merge ? "arrow.left.arrow.right" : "arrow.right")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(name(finding.implies)).font(.callout)
            }
            .lineLimit(2)

            // ⭐ Both directions, always. One percentage cannot distinguish a
            // narrow tag inside a broad one from two synonyms, and the reader
            // needs to be able to disagree with the classification.
            Text(explanation(for: finding))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    private func explanation(for finding: TagAffinity) -> String {
        let forward = percent(finding.confidence)
        let back = percent(finding.reverseConfidence)
        return "\(finding.together) videos share both. \(name(finding.tag)) brings \(name(finding.implies)) \(forward) of the time; \(name(finding.implies)) brings \(name(finding.tag)) \(back)."
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// Falls back to the identity key, which is at least recognisable, rather
    /// than showing an empty row for a tag whose record has gone missing.
    private func name(_ id: String) -> String { names[id] ?? id }

    private func header(_ title: String, count: Int, icon: String, tint: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        let result: Result<(TagAffinityReport, [String: String]), Error> = await Task.detached {
            do {
                let store = try LibraryStore(at: url)
                let report = try store.tagAffinities()
                let names = Dictionary(
                    try store.fetchTagVocabulary().map { ($0.identityKey, $0.displayName) },
                    uniquingKeysWith: { first, _ in first })
                return .success((report, names))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case let .success(found):
            report = found.0
            names = found.1
        case let .failure(error):
            failure = error.localizedDescription
        }
        isWorking = false
    }
}
