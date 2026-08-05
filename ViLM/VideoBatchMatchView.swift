// VideoBatchMatchView.swift
// Runs the video match across the library and shows what it did.
//
// The report leads with the number nobody reviewed — fields written unattended
// — because that is the figure worth being uneasy about. Everything else is
// either queued for a person or was a decision not to act.

import SwiftUI
import LibraryCore

struct VideoBatchMatchView: View {
    let libraryURLs: [URL]
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VideoBatchMatchModel
    @State private var reviewing: VideoBatchMatchModel.QueuedMatch?
    @State private var browsing: OutcomeGroup?

    struct OutcomeGroup: Identifiable {
        let title: String
        let hint: String
        let items: [VideoBatchMatchModel.QueuedMatch]
        var id: String { title }
    }

    /// The library's own tag vocabulary, so the review sheet ticks the tags you
    /// already use. Passing an empty set meant nothing was ever pre-selected.
    private var knownTags: Set<String> {
        var found = Set<String>()
        for url in libraryURLs {
            guard let assets = try? LibraryStore(at: url).fetchAllAssets() else { continue }
            for asset in assets { found.formUnion(asset.actions) }
        }
        return found
    }

    init(libraryURLs: [URL], onFinish: @escaping () -> Void) {
        self.libraryURLs = libraryURLs
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: VideoBatchMatchModel(libraryURLs: libraryURLs))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Match Videos")
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
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isRunning {
            running
        } else if model.finished {
            results
        } else {
            ContentUnavailableView {
                Label("Match every video", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Videos identified by their visual fingerprint are filled in automatically — that match is exact, not a guess. Anything found by searching is queued for you.\n\nAlready-matched videos and ones you've ruled out are skipped, so this is safe to re-run.")
            }
        }
    }

    private var running: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(model.report.examined), total: Double(max(model.total, 1)))
                .frame(maxWidth: 340)
            Text("\(model.report.examined) of \(model.total)").font(.headline)
            Text(model.current).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 340)
            HStack(spacing: 14) {
                tally("applied", model.report.applied, .green)
                tally("queued", model.report.queued, .orange)
                tally("no match", model.report.noMatch, .secondary)
            }
            // Fingerprinting reads the whole file, so this is minutes not
            // seconds. Saying so stops it looking stalled.
            Text("Fingerprinting reads each video, so this takes a while. Stopping is safe — finished videos are already saved.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .padding()
    }

    private func tally(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// A summary row that opens the files behind it.
    @ViewBuilder
    private func outcomeLink(_ label: String, _ items: [VideoBatchMatchModel.QueuedMatch],
                             hint: String) -> some View {
        if items.isEmpty {
            LabeledContent(label, value: "0")
        } else {
            Button { browsing = OutcomeGroup(title: label, hint: hint, items: items) } label: {
                HStack {
                    Text(label)
                    Spacer()
                    Text("\(items.count)").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var results: some View {
        List {
            Section {
                LabeledContent("Filled in automatically", value: "\(model.report.applied)")
                LabeledContent("Fields written unseen", value: "\(model.report.fieldsWritten)")
                LabeledContent("Queued for you", value: "\(model.report.queued)")
                // Every outcome you can act on is a way IN to the files behind
                // it. A count with no route to the videos it describes tells
                // you a problem exists and hides the only thing you could do
                // about it.
                outcomeLink("No match", model.noMatches,
                            hint: "The source has no record of these. Search by hand — a re-cut copy never matches a fingerprint even when the scene is there.")
                LabeledContent("Skipped", value: "\(model.report.skipped)")
                if !model.failures.isEmpty {
                    outcomeLink("Failed", model.failures,
                                hint: "These errored rather than answering. Worth retrying before matching by hand.")
                }
            } header: {
                Text("\(model.report.examined) videos examined")
            } footer: {
                Text("Only empty fields were filled, and only where the fingerprint matched. Nothing you had already recorded was changed, and no tags were added without you.")
            }

            if !model.queue.isEmpty {
                Section {
                    ForEach(model.queue) { item in
                        Button { reviewing = item } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.asset.fileName)
                                        .font(.caption.monospaced()).lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(item.route.displayName) · \(item.candidates.count) candidate\(item.candidates.count == 1 ? "" : "s")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Needs your eye — \(model.queue.count)")
                } footer: {
                    Text("These were found by searching rather than by fingerprint. A search returns what is plausible, which is not the same as identified.")
                }
            }
        }
        .sheet(item: $browsing) { group in
            NavigationStack {
                List {
                    Section {
                        ForEach(group.items) { item in
                            Button {
                                browsing = nil
                                // Re-presented on the next runloop so the two
                                // sheets do not fight over presentation.
                                DispatchQueue.main.async { reviewing = item }
                            } label: {
                                HStack {
                                    Text(item.asset.fileName)
                                        .font(.caption.monospaced()).lineLimit(2)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text(group.hint)
                    }
                }
                .navigationTitle("\(group.title) — \(group.items.count)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { browsing = nil }
                    }
                }
            }
        }
        .sheet(item: $reviewing) { item in
            // The library the crawl found it in — not a guess, and never a
            // fallback to "the first one".
            VideoEnrichmentSheet(asset: item.asset, libraryURL: item.libraryURL,
                                 knownTags: knownTags) { updated in
                do {
                    try LibraryStore(at: item.libraryURL).updateAsset(updated)
                    model.removeFromQueue(item.asset.id)
                } catch {
                    // Surfaced, never swallowed. A failed write here means the
                    // video silently returns to the queue next run, which is
                    // indistinguishable from the match not having been made.
                    AppErrorReporter.report(
                        "Couldn't save the match for \(item.asset.fileName): \(error.localizedDescription)")
                }
            }
            // Dismissing without applying clears the row too — you have looked.
            // The record keeps whatever state it had, so a genuinely undecided
            // video still returns on a later crawl.
            .onDisappear { model.removeFromQueue(item.asset.id) }
        }
    }
}
