// StudioBatchMatchView.swift
// Matching every studio in the library, in the app.
//
// Same shape as Match Videos and Match Actors on purpose: the same progress
// readout, the same five tallies, the same "queued" pile you can actually open.
// These are the same job done to different records, and three batch screens
// that behave differently is three things to learn.
//
// Two additions the other two have no use for, both about the hierarchy — the
// networks this run discovered, and the ones it refused to overwrite.

import SwiftUI
import LibraryCore

struct StudioBatchMatchView: View {
    let libraryURLs: [URL]
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: StudioBatchMatchModel
    @State private var reviewing: StudioBatchMatchModel.QueuedStudio?

    init(libraryURLs: [URL], onFinish: @escaping () -> Void) {
        self.libraryURLs = libraryURLs
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: StudioBatchMatchModel(libraryURLs: libraryURLs))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Match Studios")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.isRunning ? "Stop" : (model.finished ? "Done" : "Cancel")) {
                            if model.isRunning { model.cancel() }
                            else { onFinish(); dismiss() }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !model.isRunning && !model.finished {
                            Button("Start") { Task { await model.run() } }
                                .disabled(!model.hasProvider)
                        }
                    }
                }
        }
        .macSheet(minWidth: 680, minHeight: 560)
        // ⚠️ The candidate picker, NOT the profile editor.
        //
        // The actor screen hands off to its editor because the operator reaches
        // the candidates from there, via its Import button. A studio has no
        // such route — that sheet searches people — so opening the editor here
        // showed the record you already have and never the candidates that
        // caused the queue, which is the one question being asked. The
        // candidates are passed straight through; this run already paid for
        // that search.
        .sheet(item: $reviewing) { queued in
            StudioMatchReviewView(libraryURL: queued.libraryURL,
                                  profile: queued.profile,
                                  candidates: queued.candidates,
                                  existingParent: model.recordedParent(for: queued),
                                  onFinish: { outcome in
                                      // ⚠️ A decided studio leaves the queue.
                                      // Without this it stayed on the list that
                                      // asked the question while being matched
                                      // everywhere else — so the same studio
                                      // still read "needs you to choose" after
                                      // the operator had chosen.
                                      if outcome != .dismissed { model.settle(queued) }
                                      reviewing = nil
                                  })
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasProvider {
            ContentUnavailableView("No studio source installed",
                                   systemImage: "puzzlepiece.extension",
                                   description: Text("Install and configure a plugin that can look up studios, then come back."))
        } else if model.isRunning {
            running
        } else if model.finished {
            finishedReport
        } else {
            idle
        }
    }

    private var idle: some View {
        ContentUnavailableView {
            // Not `.badge.questionmark` — that variant exists for `person` and
            // not for `building.2`, and a missing symbol renders as nothing.
            Label("Match Studios", systemImage: "building.2.crop.circle")
        } description: {
            Text("Looks up every studio against \(model.providerName), and records which network owns it.\n\nThat hierarchy is the reason this exists: until now the library learned a studio's network only when a video happened to be matched, so filling the gaps meant re-matching everything.\n\nA name matching exactly one studio is filled in automatically. A name matching several is queued for you — two networks can use the same imprint name. Logos are never set unattended, nothing already filled in is overwritten, and a network you have already recorded is never replaced. Already-matched studios are skipped, so this is safe to re-run.")
        }
    }

    private var running: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(model.report.examined), total: Double(max(model.total, 1)))
                .frame(maxWidth: 340)
            Text("\(model.report.examined) of \(model.total)").font(.headline)
            if model.libraryNames.count > 1 {
                Text("scanning \(model.libraryNames.count) libraries: \(model.libraryNames.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            Text(model.current).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 340)
            // ⚠️ All five, always. `examined` is their sum, so showing a subset
            // makes the figures fail to add up and hides the one category that
            // says something is wrong.
            HStack(spacing: 14) {
                tally("applied", model.report.applied, .green)
                tally("queued", model.report.queued, .orange)
                tally("no match", model.report.noMatch, .secondary)
                tally("skipped", model.report.skipped, .secondary)
                tally("failed", model.report.failed,
                      model.report.failed > 0 ? .red : .secondary)
            }
            if model.report.parentsRecorded > 0 {
                Label("\(model.report.parentsRecorded) network\(model.report.parentsRecorded == 1 ? "" : "s") recorded",
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption).foregroundStyle(.green)
            }
            Text("Rate-limited by the source, so this takes a while. Stopping keeps everything done so far.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var finishedReport: some View {
        List {
            Section {
                LabeledContent("Confirmed", value: "\(model.report.applied)")
                LabeledContent("Fields written", value: "\(model.report.fieldsWritten)")
                LabeledContent("Networks recorded", value: "\(model.report.parentsRecorded)")
                LabeledContent("Skipped", value: "\(model.report.skipped)")
                // Kept apart from `Confirmed`: that figure is what the run did
                // unattended, and folding hand-made decisions into it would
                // credit the run with choices it explicitly refused to make.
                if model.settledByYou > 0 {
                    LabeledContent("Settled by you", value: "\(model.settledByYou)")
                }
            } header: {
                Text("Done")
            } footer: {
                Text("Skipped means already matched, ruled out, or already waiting on your decision — a re-run costs only what is left.")
            }

            // The figure that says what the run BUILT rather than what it
            // touched: these networks did not exist in the library before.
            if !model.networksDiscovered.isEmpty {
                Section {
                    ForEach(model.networksDiscovered, id: \.self) {
                        Label($0, systemImage: "building.2").font(.callout)
                    }
                } header: {
                    Text("\(model.networksDiscovered.count) new network\(model.networksDiscovered.count == 1 ? "" : "s")")
                } footer: {
                    Text("Created as studios in their own right and linked to the imprints beneath them. Their profiles are empty until you match them too.")
                }
            }

            if !model.queue.isEmpty {
                Section {
                    ForEach(model.queue) { queued in
                        Button { reviewing = queued } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(queued.name).font(.body)
                                    Text("\(queued.candidates.count) possible studios")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(model.queue.count) need you to choose")
                } footer: {
                    Text("Each of these matched more than one studio. Nothing was written for them.")
                }
            }

            // ⚠️ Reported, not resolved — and nothing was changed for these.
            if !model.conflicts.isEmpty {
                Section {
                    ForEach(model.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.studio).font(.body)
                            Text("you have \(conflict.existing) · the source says \(conflict.offered)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(model.conflicts.count) network disagreement\(model.conflicts.count == 1 ? "" : "s")")
                } footer: {
                    Text("Your record was kept. Which company owns an imprint is something you may know better than the source, so nothing was changed — change it by hand if the source is right.")
                }
            }

            // Listed rather than counted: a tally you cannot act on is a dead
            // end, and these are exactly which studios are worth doing by hand.
            if !model.noMatches.isEmpty {
                Section("\(model.noMatches.count) not found") {
                    ForEach(model.noMatches) { Text($0.name).font(.callout) }
                }
            }
            if !model.failures.isEmpty {
                Section("\(model.failures.count) failed") {
                    ForEach(model.failures) { Text($0.name).font(.callout) }
                }
            }
        }
    }

    private func tally(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
