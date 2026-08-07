// ActorBatchMatchView.swift
// Matching every actor in the library, in the app.
//
// The screen the CSV tool never had. Same shape as Match Videos on purpose:
// the same progress readout, the same five tallies, the same "queued" pile you
// can actually open — because these are the same job done to different records,
// and two batch screens that behave differently is two things to learn.

import SwiftUI
import LibraryCore

struct ActorBatchMatchView: View {
    let libraryURLs: [URL]
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ActorBatchMatchModel
    @State private var reviewing: ActorBatchMatchModel.QueuedActor?

    init(libraryURLs: [URL], onFinish: @escaping () -> Void) {
        self.libraryURLs = libraryURLs
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: ActorBatchMatchModel(libraryURLs: libraryURLs))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Match Actors")
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
        .sheet(item: $reviewing) { queued in
            // Hands off to the per-actor screen, which is where a choice
            // between candidates belongs — this run's job was to find them.
            // ⚠️ The candidate picker, NOT the profile editor.
            //
            // 🚨 This handed off to the editor, where the operator had to find
            // and press "Import from …" to reach the candidates — the same
            // dead end the studio queue had, and the one the studio fix was
            // explicitly noted as not yet applying here. It became obvious once
            // the run started finding the actors it had been blind to.
            //
            // The sheet searches on appear and opens on its picker when there
            // is more than one candidate, which is exactly why this record was
            // queued.
            if let provider = installedActorProvider {
                ActorEnrichmentSheet(
                    provider: provider,
                    entityId: queued.profile.id,
                    actorName: name(queued),
                    // The OWNING library's row, or the stand-in the run built
                    // for a name that has none — never a merged view.
                    currentProfile: queued.profile,
                    libraryURL: queued.libraryURL,
                    onApply: { merged, renameTo in
                        applyReviewed(merged, renameTo: renameTo, for: queued)
                    })
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasProvider {
            ContentUnavailableView("No actor source installed",
                                   systemImage: "puzzlepiece.extension",
                                   description: Text("Install and configure a plugin that can look up people, then come back."))
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
            Label("Match Actors", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Looks up every actor against \(model.providerName).\n\nA name matching exactly one person is filled in automatically. A name matching several is queued for you — two people share a name often enough that guessing puts the wrong bio on someone, and a recorded guess never comes back for review.\n\nPhotos are never set unattended, and nothing already filled in is overwritten. Already-matched actors and ones you've ruled out are skipped, so this is safe to re-run.")
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
                LabeledContent("Filled in", value: "\(model.report.applied)")
                LabeledContent("Fields written", value: "\(model.report.fieldsWritten)")
                LabeledContent("Skipped", value: "\(model.report.skipped)")
            } header: {
                Text("Done")
            } footer: {
                Text("Skipped means already matched, ruled out, or already waiting on your decision — a re-run costs only what is left.")
            }

            if !model.queue.isEmpty {
                Section {
                    ForEach(model.queue) { queued in
                        Button { reviewing = queued } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name(queued)).font(.body)
                                    Text("\(queued.candidates.count) possible people")
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
                    Text("Each of these matched more than one person. Nothing was written for them.")
                }
            }

            // Listed rather than counted: a tally you cannot act on is a dead
            // end, and these are exactly who is worth doing by hand.
            if !model.noMatches.isEmpty {
                Section("\(model.noMatches.count) not found") {
                    ForEach(model.noMatches) { Text(name($0)).font(.callout) }
                }
            }
            if !model.failures.isEmpty {
                Section("\(model.failures.count) failed") {
                    ForEach(model.failures) { Text(name($0)).font(.callout) }
                }
            }
        }
    }

    private var installedActorProvider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installed
            .compactMap { $0 as? any ActorMetadataProvider }
            .first
    }

    /// Saves what the operator accepted, then takes the actor off the queue.
    ///
    /// ⚠️ Writes to the library the crawl found this record in, not "the first
    /// one" — the video side learned that writing into a database with no such
    /// row throws, gets swallowed, and returns the record to the queue looking
    /// as though nothing happened.
    private func applyReviewed(_ merged: EntityProfile, renameTo: String?,
                               for queued: ActorBatchMatchModel.QueuedActor) {
        guard let store = try? LibraryStore(at: queued.libraryURL) else { return }
        // Save BEFORE any rename: a rename rewrites this record's identity, so
        // writing afterwards would target a row that has just moved.
        try? store.saveEntityProfile(merged)

        if let renameTo, !renameTo.isEmpty, renameTo != name(queued) {
            try? store.renameTagGlobally(oldTag: merged.id, newTag: "actor:\(renameTo)")
        }

        model.removeFromQueue(queued.profile.id)
        reviewing = nil
        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
    }

    private func name(_ queued: ActorBatchMatchModel.QueuedActor) -> String {
        queued.profile.id.hasPrefix("actor:")
            ? String(queued.profile.id.dropFirst(6)) : queued.profile.id
    }

    private func tally(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
