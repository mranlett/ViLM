// VideoRefreshView.swift
// Progress and results for re-reading already-matched videos.
//
// Same shape as the batch match screen deliberately: a running view, a report,
// and a queue of things only a person can settle. The difference is what it
// refuses to do — it never re-identifies anything, so nothing here can change
// which record a video is matched to.

import SwiftUI
import LibraryCore

struct VideoRefreshView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: VideoRefreshModel
    let libraryURLs: [URL]
    let onFinish: () -> Void

    @State private var reviewing: VideoRefreshModel.QueuedConflict?

    init(libraryURLs: [URL], onFinish: @escaping () -> Void) {
        _model = StateObject(wrappedValue: VideoRefreshModel(libraryURLs: libraryURLs))
        self.libraryURLs = libraryURLs
        self.onFinish = onFinish
    }

    /// Resolved the same way the batch match screen does, so a conflict opened
    /// from here offers the same tags it would there.
    private var knownTags: Set<String> {
        var found = Set<String>()
        for url in libraryURLs {
            guard let assets = try? LibraryStore(at: url).fetchAllAssets() else { continue }
            for asset in assets { found.formUnion(asset.actions) }
        }
        return found
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Refresh Matched Videos")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.isRunning ? "Stop" : "Close") {
                            if model.isRunning { model.cancel() } else { onFinish(); dismiss() }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !model.isRunning && !model.finished {
                            Button("Start") { Task { await model.run() } }
                                .disabled(model.blockedReason != nil)
                        }
                    }
                }
        }
        // ⚠️ On the container. A sheet attached to `results` would not exist
        // while `running` is on screen — the defect the consistency gate now
        // catches, found twice in this app.
        .sheet(item: $reviewing) { item in
            VideoEnrichmentSheet(asset: item.asset, libraryURL: item.libraryURL,
                                 knownTags: knownTags) { updated in
                try? LibraryStore(at: item.libraryURL).updateAsset(updated)
                model.removeFromQueue(item.asset.id)
            }
            .onDisappear { model.removeFromQueue(item.asset.id) }
        }
        .macSheet(minWidth: 480, minHeight: 440)
    }

    @ViewBuilder
    private var content: some View {
        if let blocked = model.blockedReason {
            ContentUnavailableView {
                Label("Nothing to refresh with", systemImage: "exclamationmark.triangle")
            } description: {
                Text(blocked)
            }
        } else if model.isRunning {
            running
        } else if model.finished {
            results
        } else {
            intro
        }
    }

    private var intro: some View {
        ContentUnavailableView {
            Label("Refresh Matched Videos", systemImage: "arrow.clockwise.circle")
        } description: {
            Text("Re-reads videos you have already matched, to pick up details the app could not store when the match was made — the name a performer was credited under, and the network above a studio.\n\nIt looks each video up by the record it is already matched to, so nothing is re-identified and no video changes which record it points at. Only empty fields are filled; where the source now disagrees with something you hold, it is queued for you rather than overwritten.")
        }
    }

    private var running: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(model.done), total: Double(max(model.total, 1)))
                .padding(.horizontal)
            Text("\(model.done) of \(model.total)")
                .font(.headline).monospacedDigit()
            Text(model.progress)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var results: some View {
        List {
            Section {
                tally("gained details", model.report.refreshed, .green)
                tally("already complete", model.report.alreadyComplete, .secondary)
                tally("need your eye", model.report.queued, .orange)
                tally("failed", model.report.failed,
                      model.report.failed > 0 ? .red : .secondary)
            } header: {
                Text("Examined \(model.report.examined)")
            } footer: {
                Text("“Already complete” is the expected outcome for most of a library that has been matched recently — it means the source had nothing this video was missing.")
            }

            if model.report.credits > 0 || model.report.hierarchies > 0 {
                Section {
                    if model.report.credits > 0 {
                        Label("\(model.report.credits) credited name\(model.report.credits == 1 ? "" : "s") recorded",
                              systemImage: "person.text.rectangle")
                    }
                    if model.report.hierarchies > 0 {
                        Label("\(model.report.hierarchies) studio\(model.report.hierarchies == 1 ? "" : "s") placed under a network",
                              systemImage: "building.2")
                    }
                } header: {
                    Text("What only this could recover")
                } footer: {
                    Text("A credited name belongs to one performer's appearance in one video, so no other tool can recover it.")
                }
            }

            // 🚨 Said out loud rather than folded into "skipped". These videos
            // are matched and CANNOT be refreshed — there is no record id to
            // look up — and nothing else on this screen would reveal that.
            if model.report.noSourceId > 0 {
                Section {
                    Label("\(model.report.noSourceId) matched before the app recorded which record",
                          systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("These cannot be refreshed: there is nothing to look up. Only Match Again reaches them, and that re-identifies from scratch — a full read of every video file.")
                }
            }

            if !model.queue.isEmpty {
                Section {
                    ForEach(model.queue) { item in
                        Button { reviewing = item } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.asset.fileName)
                                    .font(.caption.monospaced()).lineLimit(2)
                                    .truncationMode(.middle)
                                Text(item.fields.map(\.label).joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Disagreements — \(model.queue.count)")
                } footer: {
                    Text("The source holds a different value from the one you have. Nothing was changed; open one to see both and decide.")
                }
            }
        }
    }

    private func tally(_ label: String, _ count: Int, _ colour: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(colour)
        }
        .font(.callout)
    }
}
