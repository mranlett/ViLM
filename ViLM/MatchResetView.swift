// MatchResetView.swift
// Clears match status so videos can be matched again against the corrected
// studio handling.
//
// ⚠️ THE ONLY DESTRUCTIVE SCREEN IN THE GRAPH WORK. Everything else in this
// migration adds; this one takes away, and what it takes away cannot always be
// re-derived.
//
// The distinction the screen is built around:
//
//   matched / unresolved   a machine decided it. Clearing costs a re-run.
//   ruled out              a PERSON looked and said no. Nothing but them knows
//                          that. Clearing it destroys knowledge no re-run
//                          recreates, so it is off by default and stays off
//                          unless deliberately turned on.
//
// That asymmetry is why this is not a single "reset everything" button.

import SwiftUI
import LibraryCore

struct MatchResetView: View {
    let libraryURL: URL
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var plan: LibraryStore.MatchResetPlan?
    @State private var includeRuledOut = false
    @State private var isConfirming = false
    @State private var cleared: Int?
    @State private var isWorking = true
    @State private var errorMessage: String?

    private var affected: Int {
        guard let plan else { return 0 }
        return includeRuledOut ? plan.total : plan.clearable
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Match Again")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cleared == nil ? "Cancel" : "Done") { onFinish(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if cleared == nil, affected > 0 {
                            Button("Clear \(affected)", role: .destructive) {
                                isConfirming = true
                            }
                            .disabled(isWorking)
                        }
                    }
                }
        }
        .macSheet(minWidth: 640, minHeight: 500)
        .task { await scan() }
        // ⚠️ Confirmed rather than done on the first press. This cannot be
        // undone, and the count is the thing worth reading twice.
        .confirmationDialog("Clear match status on \(affected) videos?",
                            isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Clear \(affected)", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(includeRuledOut
                 ? "This also clears the videos you personally ruled out. Nothing but your own memory records that you looked at those, and this cannot be undone."
                 : "Videos you ruled out yourself are kept. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Reading match status…")
        } else if let errorMessage {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorMessage))
        } else if let cleared {
            ContentUnavailableView(
                "Cleared \(cleared)", systemImage: "checkmark.circle",
                description: Text("Those videos will be picked up the next time you match."))
        } else if let plan {
            List {
                Section {
                    row("Matched", plan.matched,
                        detail: "A source decided these. Re-running gets them back.")
                    row("Searched, not resolved", plan.unresolved,
                        detail: "No match, ambiguous, or waiting on review.")
                } header: {
                    Text("Will be cleared")
                }

                Section {
                    Toggle(isOn: $includeRuledOut) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Also clear \(plan.ruledOut) you ruled out")
                            // Stated in full rather than hinted at: this is the
                            // one choice on the screen that loses something a
                            // re-run cannot rebuild.
                            Text("You looked at these and said no. Nothing else in the library records that, so clearing them means seeing them all again with no way to tell which you already rejected.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(plan.ruledOut == 0)
                } header: {
                    Text("Your own decisions")
                }

                if plan.total == 0 {
                    Section {
                        Text("No video has been matched yet, so there is nothing to clear.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ count: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title, value: "\(count)")
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func scan() async {
        isWorking = true
        do {
            plan = try LibraryStore(at: libraryURL).planMatchReset()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func apply() async {
        isWorking = true
        do {
            cleared = try LibraryStore(at: libraryURL)
                .resetMatchStatus(includingRuledOut: includeRuledOut)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}
