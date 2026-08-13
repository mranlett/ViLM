// SourceGapView.swift
// What else are they in, that I do not have? (#41, #42, #43)
//
// TRACKED and PUBLIC. Names no source — every label comes from the provider.
//
// ⭐ ONE screen for both entry points. A profile's "what else is she in" is a
// sweep of one, and building two screens would mean two places for the
// confidence line to drift out of step — which is the one thing this feature
// cannot afford, since the line is what makes the list trustworthy.
//
// 🚨 Read-only (#43). Nothing here writes to the library. The app says "these
// exist and you do not have them" and stops: no fetching, no acquiring, no
// links followed automatically.

import SwiftUI
import LibraryCore

struct SourceGapView: View {
    /// Empty means the top-tier / random sweep; one entry means a profile.
    let performers: [EntityProfile]
    let allProfiles: [EntityProfile]
    let libraryURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var results: [Result] = []
    @State private var basis: SourceGapService.SweepBasis?
    @State private var progress: (done: Int, total: Int)?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var task: Task<Void, Never>?

    struct Result: Identifiable {
        let id: String
        let name: String
        let report: SourceGapReport?
        let failure: String?
    }

    private var provider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installedActorProviders().first
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(performers.count == 1 ? "Also In" : "What You're Missing")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { task?.cancel(); dismiss() }
                    }
                    if isRunning {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Stop") { task?.cancel(); isRunning = false }
                        }
                    }
                }
                .task { start() }
        }
        .macSheet(minWidth: 520, minHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(.orange)
                Text(errorMessage).font(.callout).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if let basis, performers.count != 1 {
                    Section {
                        // ⚠️ Says WHICH basis. An early sweep presented without
                        // this reads as a ranked recommendation and is judged
                        // as one.
                        Label(basis == .topTier
                              ? "Your highest-ranked performers."
                              : "A random selection — your ranking does not have enough settled performers yet to draw a top tier from.",
                              systemImage: basis == .topTier ? "trophy" : "shuffle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let progress, isRunning {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Asked about \(progress.done) of \(progress.total)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(results) { result in
                    Section {
                        if let report = result.report {
                            reportBody(report)
                        } else if let failure = result.failure {
                            Text(failure).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(result.name)
                    }
                }

                if !isRunning && results.isEmpty {
                    Text("Nothing to ask about.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }

    @ViewBuilder
    private func reportBody(_ report: SourceGapReport) -> some View {
        // 🔴 D1 — the confidence line, first and always. A list without it
        // invites the operator to trust it uniformly, which is exactly what the
        // measurement says they should not do.
        Text(report.confidence)
            .font(.caption)
            .foregroundStyle(report.isExact ? .secondary : .primary)

        if report.sourceTruncated {
            // ⚠️ A capped answer under-reports, and fewer results looks like
            // good news. Said out loud rather than inferred by the reader.
            Label("The source returned as many as it will at once — there may be more.",
                  systemImage: "ellipsis.circle")
                .font(.caption2).foregroundStyle(.orange)
        }

        ForEach(report.gaps) { gap in
            VStack(alignment: .leading, spacing: 2) {
                Text(gap.title).font(.callout).lineLimit(2)
                let detail = [gap.releaseDate, gap.studioName].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Running

    private func start() {
        guard !isRunning, results.isEmpty else { return }
        guard let provider else {
            errorMessage = SourceGapService.Failure.noProvider.errorDescription
            return
        }
        guard let libraryURL else { return }

        let chosen: [EntityProfile]
        if performers.count == 1 {
            chosen = performers
            basis = nil
        } else {
            let standings = PreferenceStandings.load(for: allProfiles, subject: .actor,
                                                     fallback: libraryURL)
            var generator = SystemRandomNumberGenerator()
            let selection = SourceGapService.selectSweep(from: allProfiles,
                                                         standings: standings,
                                                         using: &generator)
            basis = selection.basis
            chosen = selection.profiles
        }

        isRunning = true
        progress = (0, chosen.count)
        task = Task {
            // ⚠️ Sequential, never concurrent. Fifty simultaneous requests is
            // how a rate limit is discovered the hard way, and the operator
            // gains nothing from them arriving out of order.
            for (index, profile) in chosen.enumerated() {
                if Task.isCancelled { break }
                var result: Result
                do {
                    let report = try await SourceGapService.report(for: profile,
                                                                   provider: provider,
                                                                   libraryURL: libraryURL)
                    result = Result(id: profile.id, name: profile.name,
                                    report: report, failure: nil)
                } catch {
                    result = Result(id: profile.id, name: profile.name,
                                    report: nil, failure: error.localizedDescription)
                }
                await MainActor.run {
                    // ⭐ Appended as they arrive, and cancelling KEEPS what was
                    // already found. Thirty answers are worth having even if
                    // the operator stopped at thirty.
                    results.append(result)
                    progress = (index + 1, chosen.count)
                }
            }
            await MainActor.run { isRunning = false }
        }
    }
}
