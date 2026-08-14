// TwoHopDiscoveryView.swift
// Performers connected by studios, never by a video.
//
// ⭐ From *What the Graph Could Answer*, section D — and the spike's own
// argument for the Epic: "reachable in one query, unanswerable from strings."
// Nothing in any single record connects two people who have never appeared
// together. Only the path through a studio does.
//
// 🚨 The threshold is exposed, not hidden. On the measured library the counts
// fall off a cliff — 35,458 pairs share one studio, 2,048 share two, 285 share
// three, 48 share four — so any fixed floor is a judgement, and burying it
// would present one arbitrary slice as the answer. The operator can move it and
// watch the list change, which is the honest version of picking a default.
//
// ⚠️ Describes, does not correct. Filed under Explore the Graph: nothing here
// is wrong.

import SwiftUI
import LibraryCore

struct TwoHopDiscoveryView: View {
    let libraryURL: URL
    /// Opens a performer. The parent dismisses this sheet first — presenting
    /// one sheet while another closes is how the second silently fails.
    var onOpenPerformer: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Persisted, because the operator who moved it once meant it.
    @AppStorage("twoHopMinimumSharedStudios") private var floor: Int = 3

    @State private var report: TwoHopReport?
    @State private var names: [String: String] = [:]
    @State private var isWorking = true
    @State private var failure: String?

    /// ⚠️ Bounded. 285 rows at the default floor is a list; the whole 35,458 at
    /// a floor of one is a scroll with no end, and building it would stall the
    /// screen it is on.
    private let shown = 50

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Never Worked Together")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .macSheet(minWidth: 720, minHeight: 600)
        .task(id: floor) { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Walking studio to performer…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if let report {
            List {
                Section {
                    Picker("Share at least", selection: $floor) {
                        ForEach([2, 3, 4, 5], id: \.self) { Text("\($0) studios").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(summary(report))
                }

                if report.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No pairs at this threshold", systemImage: "person.2.slash")
                        } description: {
                            Text("Nobody shares this many studios without having appeared together. Lower the threshold to widen the search.")
                        }
                    }
                } else {
                    Section {
                        ForEach(report.neighbours.prefix(shown)) { row($0) }
                        if report.neighbours.count > shown {
                            // ⚠️ Whatever is cut is counted and said out loud.
                            Text("and \(report.neighbours.count - shown) more, less closely connected")
                                .font(.callout).foregroundStyle(.tertiary)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                            Text("Connected by studios")
                            Spacer()
                            Text("\(report.neighbours.count)").monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Ordered by how much of each performer's working life the other accounts for — sharing three studios out of four is a far closer connection than three out of forty, and both numbers are shown so you can disagree.")
                    }
                }
            }
        }
    }

    private func row(_ neighbour: StudioNeighbour) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button { open(neighbour.performer) } label: {
                    Text(name(neighbour.performer)).font(.callout)
                }
                .buttonStyle(.plain)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button { open(neighbour.other) } label: {
                    Text(name(neighbour.other)).font(.callout)
                }
                .buttonStyle(.plain)
            }
            .lineLimit(1)

            Text("\(neighbour.sharedStudios) studios in common, of \(neighbour.performerStudios) and \(neighbour.otherStudios) — \(percent(neighbour.overlap)) overlap")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    /// 🚨 States what was filtered out, beside what was found. "285 pairs" over
    /// an unstated population reads as a discovery; over 38,098 it reads as
    /// what it is.
    private func summary(_ report: TwoHopReport) -> String {
        "\(report.pairsSharingAStudio) pairs of performers share at least one studio. \(report.alreadyCoStarred) of those have already appeared together and are not offered — this screen is for the ones you have never seen in the same video."
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func name(_ id: String) -> String { names[id] ?? id }

    private func open(_ performerId: String) {
        onOpenPerformer(name(performerId))
        dismiss()
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        let minimum = floor
        let result: Result<(TwoHopReport, [String: String]), Error> = await Task.detached {
            do {
                let store = try LibraryStore(at: url)
                let report = try store.studioNeighbours(
                    thresholds: .init(minimumSharedStudios: minimum))
                let names = Dictionary(
                    try store.fetchAllEntityProfiles()
                        .filter { $0.type == "actor" }
                        .map { ($0.id, $0.name) },
                    uniquingKeysWith: { first, _ in first })
                return .success((report, names))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case let .success(found):
            report = found.0
            names = found.1
        case let .failure(error):
            failure = error.localizedDescription
        }
        isWorking = false
    }
}
