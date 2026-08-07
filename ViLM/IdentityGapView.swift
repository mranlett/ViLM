// IdentityGapView.swift
// Records that claim to be matched and hold no external identity.
//
// 🚨 The screen the match-edge work exists to make possible. Before it, a null
// `enrichmentSourceId` beside `enrichmentState = matched` was indistinguishable
// from a record nobody had looked up — invisible, and unreachable, because
// every matching tool skips anything already matched.
//
// ⭐ It reports and does not repair, like Impossible Data. But unlike a flat
// list it answers the question that decides what to do: for each record, is
// there a route back? A performer credited on a MATCHED video can be recovered
// by refreshing it, because the source's scene record links to their confirmed
// profile. One credited only on unmatched videos needs a person.

import SwiftUI
import LibraryCore

struct IdentityGapView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    var onRefreshVideos: (() -> Void)?

    @State private var report: IdentityGapReport?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private static let examplesShown = 40

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Missing Identities")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: { Text(errorMessage ?? "") }
                .task { await load() }
        }
        .macSheet(minWidth: 560, minHeight: 520)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Checking every matched record…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report, report.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 40)).foregroundStyle(.green)
                Text("Every matched record carries an identity")
                    .font(.title3).multilineTextAlignment(.center)
                Text("Each one can be looked up again directly, without searching by name and guessing which record was meant.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report {
            List {
                Section {
                    Text(report.headline).font(.callout)
                } footer: {
                    Text("These records say a lookup matched them, but nothing recorded WHICH record it matched. Every matching tool skips them, because they are already marked matched — so they cannot be repaired by running one again.")
                }

                if !report.recoverable.isEmpty {
                    section(report.recoverable, title: "Recoverable automatically",
                            icon: "arrow.clockwise.circle", tint: .green,
                            footer: "Each of these appears in a video that IS matched. The source's record for that video links to their confirmed profile, so Refresh Matched Videos hands the identity down — no searching, no choosing.")
                }

                if !report.needsAPerson.isEmpty {
                    section(report.needsAPerson, title: "Need you",
                            icon: "person.crop.circle.badge.questionmark", tint: .orange,
                            footer: "⚠️ No matched video links to these, so there is nothing to hand an identity down from. Each needs looking up by name — and because they are marked matched, the batch tools will not offer to. Open one and use Match Again on its profile.")
                }

                if !report.recoverable.isEmpty, let onRefreshVideos {
                    Section {
                        Button("Refresh Matched Videos…") {
                            dismiss()
                            onRefreshVideos()
                        }
                    } footer: {
                        Text("Runs the tool that recovers the first group. It re-reads each matched video by the record it already points at — no re-identification.")
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func section(_ gaps: [IdentityGap], title: String, icon: String,
                         tint: Color, footer: String) -> some View {
        Section {
            ForEach(gaps.prefix(Self.examplesShown)) { gap in
                HStack(spacing: 8) {
                    Image(systemName: gap.kind == .actor ? "person" : "building.2")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(width: 14)
                    Text(gap.displayName).font(.callout)
                    Spacer()
                    // ⚠️ Both numbers, because their RATIO is the point: "in 9
                    // videos, 2 matched" says a refresh will reach them and the
                    // other seven still will not be identified by it.
                    Text(gap.matchedVideoCount > 0
                         ? "\(gap.videoCount) video\(gap.videoCount == 1 ? "" : "s") · \(gap.matchedVideoCount) matched"
                         : "\(gap.videoCount) video\(gap.videoCount == 1 ? "" : "s")")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if gaps.count > Self.examplesShown {
                // ⚠️ Said out loud. A list that quietly stops at forty reads as
                // a library with forty of these.
                Text("…and \(gaps.count - Self.examplesShown) more")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } header: {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title)
                Spacer()
                Text("\(gaps.count)").monospacedDigit().foregroundStyle(.secondary)
            }
        } footer: {
            Text(footer)
        }
    }

    private func load() async {
        do {
            let url = libraryURL
            let found = try await Task.detached(priority: .userInitiated) {
                try LibraryStore(at: url).identityGaps()
            }.value
            await MainActor.run {
                self.report = found
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Couldn't read the library: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}
