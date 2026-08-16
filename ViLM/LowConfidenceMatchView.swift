// LowConfidenceMatchView.swift
// Fingerprint matches the source's own data does not strongly support.
//
// 🔴 REPORT AND OPEN, NEVER REJECT. A low-confidence match is still very often
// right (D4). Every row here is an invitation to look at one video; there is no
// bulk action, no "clear all", and nothing on this screen un-matches anything.
// The doubt is evidence for a person, not an instruction to the app.
//
// ⭐ Built like Gone at the Source and Studio Health: same detached scan, same
// counted-and-said-out-loud truncation, same refusal to invent a repair. Three
// audit screens that behave differently is three things to learn.

import SwiftUI
import LibraryCore

struct LowConfidenceMatchView: View {
    let libraryURL: URL
    /// Opens a video. The parent dismisses this sheet first — presenting one
    /// sheet while another is closing is how the second silently fails.
    var onOpenVideo: (Asset.ID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var findings: [LowConfidenceMatch] = []
    @State private var unassessed = 0
    @State private var isWorking = true
    @State private var failure: String?

    private let examplesShown = 50

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Doubtful Matches")
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
        .macSheet(minWidth: 720, minHeight: 560)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Looking at every fingerprint match…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else {
            List {
                summarySection
                if !findings.isEmpty { findingsSection }
            }
        }
    }

    /// 🚨 The denominator, always. An empty list over hundreds of matches
    /// nobody has assessed is NOT a clean library, and a screen that showed
    /// only "nothing to review" would be saying something it cannot know.
    @ViewBuilder
    private var summarySection: some View {
        Section {
            if findings.isEmpty {
                Label("Nothing to review", systemImage: "checkmark.seal")
                    .font(.callout)
            } else {
                Label("^[\(findings.count) match](inflect: true) worth a second look",
                      systemImage: "questionmark.circle")
                    .font(.callout)
            }
            if unassessed > 0 {
                Label("^[\(unassessed) fingerprint match](inflect: true) carries no confidence at all — the source has not been asked, or does not publish it.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("These are matches the source's own data does not strongly support. Nothing here is wrong on its own, and nothing on this screen changes a match — a doubtful match is very often the right one. Open a video to judge it.")
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        Section {
            ForEach(findings.prefix(examplesShown)) { finding in
                Button {
                    let id = finding.videoId
                    dismiss()
                    onOpenVideo(id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.title).font(.callout)
                        ForEach(finding.doubts, id: \.self) { doubt in
                            Label(detail(doubt, finding), systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let asOf = finding.asOf {
                            // ⚠️ The as-of, shown. A submission count is a
                            // snapshot of a crowd that keeps moving, and a
                            // number with no date invites acting on a stale one.
                            Text("Recorded \(asOf.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Worth a look")
        } footer: {
            if findings.count > examplesShown {
                Text("Showing \(examplesShown) of \(findings.count).")
            }
        }
    }

    /// ⚠️ Both runtimes, not "they disagree". 28:14 against 61:02 reads as a
    /// different cut at a glance; "the durations disagree" is a claim the
    /// operator has to go and verify.
    private func detail(_ doubt: MatchDoubt, _ finding: LowConfidenceMatch) -> String {
        switch doubt {
        case .durationDisagrees:
            let local = Self.clock(finding.localDuration)
            let claimed = Self.clock(finding.claimedDuration)
            return "This file runs \(local); the source's fingerprint came from \(claimed)."
        case .singleSubmission:
            return doubt.reason
        }
    }

    private static func clock(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "an unknown length" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        // ⚠️ `.utility` — a sweep of every fingerprint match with its own
        // progress view. See QoSConventionTests for the rule.
        let outcome = await Task.detached(priority: .utility) {
            () -> Result<([LowConfidenceMatch], Int), Error> in
            do {
                let store = try LibraryStore(at: url)
                return .success((try store.lowConfidenceMatches(),
                                 try store.fingerprintMatchesWithoutConfidence()))
            } catch { return .failure(error) }
        }.value

        switch outcome {
        case let .success((found, silent)):
            findings = found
            unassessed = silent
        case let .failure(error):
            failure = error.localizedDescription
        }
        isWorking = false
    }
}
