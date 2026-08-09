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

    /// ⭐ Remembered. Someone who works this queue quickest-first wants that
    /// every run, and re-choosing it each time is friction on the exact
    /// workflow the setting exists to speed up.
    @AppStorage("matchQueueOrder") private var queueOrderRaw = MatchQueueOrder.easiest.rawValue

    private var queueOrder: MatchQueueOrder {
        get { MatchQueueOrder(rawValue: queueOrderRaw) ?? .easiest }
        nonmutating set { queueOrderRaw = newValue.rawValue }
    }

    /// The queue as the operator asked to see it.
    private var orderedQueue: [VideoBatchMatchModel.QueuedMatch] {
        queueOrder.arrange(model.queue) {
            MatchQueueEntry(route: $0.route, candidateCount: $0.candidates.count)
        }
    }

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

    /// - Parameter scope: restricts the run to a subset — a performer's or a
    ///   studio's films. `nil` runs the whole library, which is what Settings
    ///   asks for.
    init(libraryURLs: [URL],
         scope: VideoBatchMatchModel.Scope? = nil,
         onFinish: @escaping () -> Void) {
        self.libraryURLs = libraryURLs
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: VideoBatchMatchModel(libraryURLs: libraryURLs,
                                                                scope: scope))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.isScoped ? "Match These Videos" : "Match Videos")
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
                            // Disabled rather than allowed-then-silent: a run
                            // that cannot authenticate looks identical to a
                            // library the source has never heard of.
                            Button("Start") { Task { await model.run() } }
                                .disabled(model.blockedReason != nil)
                        }
                    }
                }
        }
        // ⚠️ macOS sheets size to their content, and `List` has no intrinsic
        // height — so when the screen switched from the running VStack to the
        // results List, the sheet collapsed to a title bar and a Close button.
        // The report was rendering correctly the whole time; there was simply
        // no room to draw it, which read as "the run reported nothing".
        // 🚨 On the CONTAINER, not on `results`.
        //
        // These lived on the results view — but `tally`, which SETS `browsing`,
        // is rendered by `running`. So DURING a run, tapping a tally did
        // nothing at all. It looked fine because a finished run shows
        // `results`, where the sheet did exist. Same defect as the match
        // screen, found by the same scan.
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
            // 🚨 A sheet WITHIN a sheet inherits nothing — the outer frame below
            // does not reach it. Without this the group opened as a title bar
            // and a Close button with no content area, so "No match — 1" listed
            // nothing and the one route to matching that video by hand was
            // unreachable. The list was rendering the whole time.
            .macSheet(minWidth: 460, minHeight: 380)
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
        .macSheet(minWidth: 460, minHeight: 420)
    }

    @ViewBuilder
    private var content: some View {
        if model.isRunning {
            running
        } else if model.finished {
            results
        } else if let blocked = model.blockedReason {
            // Said up front, where the Start button is, rather than discovered
            // after a full pass over the library produced nothing.
            ContentUnavailableView {
                Label("Nothing to match with", systemImage: "exclamationmark.triangle")
            } description: {
                Text(blocked)
            }
        } else {
            ContentUnavailableView {
                Label(model.isScoped ? "Match these videos" : "Match every video",
                      systemImage: "sparkle.magnifyingglass")
            } description: {
                // ⚠️ A scoped run says WHAT it covers before it starts. The
                // screen is otherwise identical to the whole-library one, and
                // "Match every video" on a page showing forty of two thousand
                // is the kind of wording that gets a run cancelled halfway out
                // of doubt about what it is doing.
                Text((model.scopeLabel.map { "\($0)\n\n" } ?? "")
                     + "Videos identified by their visual fingerprint are filled in automatically — that match is exact, not a guess. Anything found by searching is queued for you.\n\nAlready-matched videos and ones you've ruled out are skipped, so this is safe to re-run.")
            }
        }
    }

    private var running: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(model.report.examined), total: Double(max(model.total, 1)))
                .frame(maxWidth: 340)
            Text("\(model.report.examined) of \(model.total)").font(.headline)
            // Says WHICH libraries are being scanned. A run that silently
            // included a second library read as "it is scanning the same files
            // over and over" — the count was right and the explanation was
            // invisible. Naming them makes that immediate instead of a mystery.
            if model.libraryNames.count > 1 {
                Text("scanning \(model.libraryNames.count) libraries: \(model.libraryNames.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            Text(model.current).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 340)
            // ⚠️ ALL FIVE, always — `examined` is their sum, so showing three
            // of them made the figures fail to add up and hid the one category
            // that says something is wrong. A run reporting "111 examined, 47
            // no match" left 64 videos unaccounted for, and they were failures.
            HStack(spacing: 14) {
                tally("applied", model.report.applied, .green)
                tally("queued", model.report.queued, .orange)
                tally("no match", model.report.noMatch, .secondary)
                tally("skipped", model.report.skipped, .secondary)
                tally("failed", model.report.failed,
                      model.report.failed > 0 ? .red : .secondary)
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
                    Picker("Order", selection: Binding(
                        get: { queueOrder }, set: { queueOrder = $0 })) {
                        ForEach(MatchQueueOrder.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(queueOrder.explanation)
                        .font(.caption2).foregroundStyle(.secondary)
                } header: {
                    Text("Needs your eye — \(model.queue.count)")
                }

                Section {
                    ForEach(orderedQueue) { item in
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
                } footer: {
                    Text("These were found by searching rather than by fingerprint. A search returns what is plausible, which is not the same as identified.")
                }
            }
        }
    }
}
