// MediaFactsBackfillView.swift
// The operator's view of F6 Stage B (#10).
//
// 🚨 THIS is where progress and cancellation earn their place. Stage A is stat
// calls — milliseconds over a whole library — and giving it a progress bar
// would have been ceremony. Stage B opens every unmeasured file and parses its
// headers, so the operator is going to wait, and a wait with no number and no
// way out is what makes people force-quit an app mid-write.

import SwiftUI
import LibraryCore

struct MediaFactsBackfillView: View {
    let libraryURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var progress: StageBSummary?
    @State private var isRunning = false
    @State private var finished = false
    @State private var failure: String?

    /// ⚠️ Read by the running task, written from the main actor. A plain flag
    /// is enough: it is set once, never unset, and a late read costs one more
    /// file rather than anything that matters.
    @State private var cancelRequested = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Reads the length, size and format of every video and stores them, so the inspector stops reopening files to show numbers it could have remembered.")
                        .font(.callout)
                } footer: {
                    // 🚨 Said plainly BEFORE it starts. This opens every file.
                    Text("This opens every video that has not been measured, so it takes a while and is slower on an external drive. Stopping is safe — whatever has been measured stays measured, and anything left simply gets read from the file as it does today.")
                }

                if let progress {
                    Section("Progress") {
                        row("Measured", progress.measured)
                        if progress.unchanged > 0 { row("Already known", progress.unchanged) }
                        if progress.remaining > 0 { row("Not reached", progress.remaining) }
                        if !progress.unreadable.isEmpty {
                            // 🚨 Named, not just counted. A number here is a
                            // dead end for the one person who could do
                            // something about these.
                            DisclosureGroup("Could not be read (\(progress.unreadable.count))") {
                                ForEach(progress.unreadable.prefix(50), id: \.self) { path in
                                    Text(path).font(.caption).foregroundStyle(.secondary)
                                }
                                if progress.unreadable.count > 50 {
                                    Text("…and \(progress.unreadable.count - 50) more")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.callout) }
                }

                Section {
                    if isRunning {
                        Button(role: .destructive) { cancelRequested = true } label: {
                            Label("Stop", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(cancelRequested)
                    } else if !finished {
                        Button { Task { await run() } } label: {
                            Label("Measure Videos", systemImage: "ruler")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Measure Videos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished || !isRunning ? "Close" : "Hide") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private func row(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func run() async {
        isRunning = true
        failure = nil
        let url = libraryURL
        do {
            let store = try LibraryStore(at: url)
            let result = try await store.backfillMediaFacts(
                libraryURL: url,
                isCancelled: { cancelRequested },
                onProgress: { snapshot in
                    Task { @MainActor in progress = snapshot }
                })
            progress = result
            finished = true
        } catch {
            failure = error.localizedDescription
        }
        isRunning = false
    }
}
