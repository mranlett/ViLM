// SeriesTitleRepairView.swift
// Titles filed under a series of their own.
//
// ⭐ The operator uses the series field for two different things, and only one
// of them is a mistake:
//
//   • a series the SOURCE supplied, or a grouping THEY built to sequence a
//     studio's videos by episode number — legitimate, and there is no other way
//     for the app to render those in order
//   • a title that ended up in the series box, giving one video a series of
//     its own
//
// 🚨 So the screen leads with what it is NOT going to touch. A repair that
// flattened a hand-built sequencing group would destroy structure no source can
// give back, and the operator has to be able to see that it will not.

import SwiftUI
import LibraryCore

struct SeriesTitleRepairView: View {
    let libraryURL: URL
    var onRefresh: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var report: SeriesTitleRepair.Report?
    @State private var isLoading = true
    @State private var failure: String?
    @State private var repaired = 0
    @State private var isRepairing = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Titles in the Series Field")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            if repaired > 0 { onRefresh() }
                            dismiss()
                        }
                    }
                }
                .overlay {
                    if isRepairing {
                        ProgressView("Repairing…")
                            .padding().background(.regularMaterial).cornerRadius(10)
                    }
                }
                .task { await load() }
        }
        .macSheet(minWidth: 620, minHeight: 540)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Comparing series against titles…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if let report {
            if report.repairable.isEmpty && report.needsAPerson.isEmpty {
                ContentUnavailableView {
                    Label(repaired > 0 ? "\(repaired) repaired" : "Every series names a real grouping",
                          systemImage: "checkmark.seal")
                } description: {
                    Text("No video has a series of its own. \(report.preservedGroupings) grouping\(report.preservedGroupings == 1 ? "" : "s") left exactly as they are.")
                }
            } else {
                list(report)
            }
        }
    }

    private func list(_ report: SeriesTitleRepair.Report) -> some View {
        List {
            Section {
                Text(SeriesTitleRepair.headline(report)).font(.callout)
                if repaired > 0 {
                    Text("\(repaired) repaired just now")
                        .font(.caption).foregroundStyle(.green)
                }
            } footer: {
                // ⭐ States the refusal first. The operator's sequencing groups
                // are the thing most at risk here, and they need to see the
                // rule before they press anything.
                Text("A series is left alone whenever it groups more than one video, or carries an episode number — those are how you sequence a studio's videos, and no source can rebuild them. Only a series belonging to a single unsequenced video is treated as a title.")
            }

            if !report.repairable.isEmpty {
                Section {
                    Button("Repair \(report.repairable.count)") { repair() }
                        .disabled(isRepairing)
                } header: {
                    Text("Safe to repair")
                } footer: {
                    let dupes = report.repairable.filter { $0.kind == .duplicated }.count
                    let moved = report.repairable.count - dupes
                    Text("\(dupes) where the series simply repeats the title — the series is cleared. \(moved) where the title is in the series box and the title is empty — it moves across.")
                }
            }

            if !report.needsAPerson.isEmpty {
                Section {
                    ForEach(report.needsAPerson.prefix(40)) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.episode).font(.callout).lineLimit(1)
                            Text("series: \(item.series)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if report.needsAPerson.count > 40 {
                        Text("and \(report.needsAPerson.count - 40) more")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Need you")
                } footer: {
                    // ⚠️ Reported rather than guessed. Both boxes hold different
                    // text, so choosing between them is a judgement, and being
                    // wrong discards a real title.
                    Text("Both fields are filled with different text. The series might be a genuine one-off, so nothing here is changed automatically — open the video and set them the way you want.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func repair() {
        let url = libraryURL
        isRepairing = true
        Task {
            let outcome: Result<Int, Error> = await Task.detached(priority: .utility) {
                do { return .success(try LibraryStore(at: url).repairSeriesTitles()) }
                catch { return .failure(error) }
            }.value

            switch outcome {
            case let .success(count): repaired += count
            case let .failure(error): failure = error.localizedDescription
            }
            isRepairing = false
            await load()
        }
    }

    private func load() async {
        isLoading = true
        failure = nil
        let url = libraryURL
        let result: Result<SeriesTitleRepair.Report, Error> = await Task.detached {
            do { return .success(try LibraryStore(at: url).seriesTitleReport()) }
            catch { return .failure(error) }
        }.value

        switch result {
        case let .success(found): report = found
        case let .failure(error): failure = error.localizedDescription
        }
        isLoading = false
    }
}
