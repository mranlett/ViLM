// StudioSignaturesView.swift
// When in a career each studio works.
//
// ⭐ The operator's own question from *What the Graph Could Answer*: "studios
// feature different actors at different times — beginning of career, end of a
// career." The answer is a claim no single record supports and the graph makes
// easily: each `video_studio` edge reaches a release date through its video and
// a career start through its cast, and the difference is how far into a career
// that appearance was.
//
// 🚨 Most studios are ordinary, and the screen says so out loud. A screen where
// every studio has a striking character is a screen nobody believes — so
// "established" is reported as the plain majority it is, and only the two ends
// are presented as findings.
//
// ⚠️ It describes, it does not correct. Filed under Explore the Graph rather
// than Find Problems for that reason: nothing here is wrong.

import SwiftUI
import LibraryCore

struct StudioSignaturesView: View {
    let libraryURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var report: StudioSignatureReport?
    @State private var names: [String: String] = [:]
    @State private var isWorking = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Studio Signatures")
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
        .macSheet(minWidth: 720, minHeight: 600)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Placing every appearance in a career…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if let report {
            if report.isEmpty {
                ContentUnavailableView {
                    Label("Not enough to go on yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Placing an appearance in a career needs four things to line up: the video's studio, its cast, its release date, and the performer's career start. No studio has five such appearances yet.")
                }
            } else {
                findings(report)
            }
        }
    }

    private func findings(_ report: StudioSignatureReport) -> some View {
        List {
            section(report, .discovery,
                    title: "Works with newcomers",
                    icon: "sunrise", tint: .orange,
                    footer: "Half or more of these studios' appearances are in somebody's first two years. On the graph spike's reading, a discovery house.")

            section(report, .lateCareer,
                    title: "Works late in careers",
                    icon: "sunset", tint: .purple,
                    footer: "A median of a decade or more into a career — a late-career or redistribution label rather than a house that starts them.")

            section(report, .established,
                    title: "Neither, particularly",
                    icon: "circle.dashed", tint: .secondary,
                    footer: "The ordinary majority, listed so the two groups above can be read as unusual rather than as the whole picture.")

            Section {
                Text(caveat(report))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("What this is built from")
            }
        }
    }

    @ViewBuilder
    private func section(_ report: StudioSignatureReport,
                         _ character: StudioSignature.Character,
                         title: String, icon: String, tint: Color,
                         footer: String) -> some View {
        let rows = report.signatures.filter { $0.character == character }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row($0) }
            } header: {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(title)
                    Spacer()
                    Text("\(rows.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                Text(footer)
            }
        }
    }

    private func row(_ signature: StudioSignature) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(names[signature.studioId] ?? signature.studioId)
                .font(.callout)
                .lineLimit(1).truncationMode(.middle)
            // ⚠️ Observations AND distinct performers. Twenty appearances by
            // one performer is not twenty pieces of evidence, and only the two
            // numbers together show the difference.
            Text("median \(median(signature)) into a career · \(percent(signature.shareInFirstTwoYears)) in the first two years · \(signature.observations) appearances by \(signature.performers) performer\(signature.performers == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    private func median(_ signature: StudioSignature) -> String {
        let value = signature.medianYearsIntoCareer
        let text = value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
        return "\(text) year\(value == 1 ? "" : "s")"
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// 🚨 Says what was left out, in the same breath as what was found. A
    /// signature computed from a fraction of a catalogue, presented without
    /// that fraction, is a stronger claim than the data supports.
    private func caveat(_ report: StudioSignatureReport) -> String {
        var parts = ["An appearance counts only when the video has a studio, a cast, a release date, and the performer has a recorded career start."]
        if report.studiosBelowEvidenceFloor > 0 {
            parts.append("\(report.studiosBelowEvidenceFloor) more studios were seen but had fewer than five such appearances — too few to call a signature.")
        }
        if report.impossibleObservations > 0 {
            parts.append("\(report.impossibleObservations) appearances were left out entirely because the video predates the performer's recorded career start: those are two records contradicting each other, and Impossible Data lists them.")
        }
        return parts.joined(separator: " ")
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        let result: Result<(StudioSignatureReport, [String: String]), Error> = await Task.detached {
            do {
                let store = try LibraryStore(at: url)
                let report = try store.studioSignatures()
                let names = Dictionary(
                    try store.fetchAllEntityProfiles()
                        .filter { $0.type == "studio" }
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
