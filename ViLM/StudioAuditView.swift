// StudioAuditView.swift
// The state of the studios, in one screen.
//
// Belongs in Find Problems, whose footer already promises "These report rather
// than change anything" — and this changes nothing. Every repair here already
// has a screen that does it carefully and asks the right question first, so
// each finding is a row that takes you there rather than a button that acts.
//
// ⚠️ Single-library on purpose, and disabled while federated. Half of these
// findings are about edges, edges live inside one library and point at rows in
// it, so a combined answer across two libraries would be half a real audit and
// half a category error. Connect the Graph is scoped the same way for the same
// reason.

import SwiftUI
import LibraryCore

struct StudioAuditView: View {
    let libraryURL: URL
    /// Opens the screen that resolves a finding. The parent dismisses this
    /// sheet first — presenting one sheet while another is closing is how the
    /// second one silently fails to appear.
    var onFix: (StudioFix) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var checks: [StudioCheck] = []
    @State private var isWorking = true
    @State private var failure: String?

    /// How many examples each finding shows before it stops listing them.
    ///
    /// ⚠️ Whatever is cut is COUNTED and said out loud. A list that quietly
    /// stops at a dozen reads as a library with a dozen problems.
    private let examplesShown = 12

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Studio Health")
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
        .macSheet(minWidth: 700, minHeight: 560)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Reading the studios…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if checks.isEmpty {
            ContentUnavailableView {
                Label("Studios look healthy", systemImage: "checkmark.seal")
            } description: {
                Text("Every studio has a profile, is confirmed, is spelled one way, and is connected to the graph. No video carries two studios, and every network on record exists.")
            }
        } else {
            findings
        }
    }

    private var findings: some View {
        List {
            Section {
                Text(headline)
                    .font(.callout)
            } footer: {
                Text("Nothing here has been changed. Each finding opens the tool that resolves it.")
            }

            ForEach(checks) { check in
                Section {
                    ForEach(check.items.prefix(examplesShown), id: \.self) { item in
                        Text(item)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if check.count > examplesShown {
                        Text("and \(check.count - examplesShown) more")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    fixRow(for: check)
                } header: {
                    HStack {
                        Image(systemName: check.isDefect
                              ? "exclamationmark.triangle.fill" : "clock.badge")
                            .foregroundStyle(check.isDefect ? .orange : .secondary)
                        Text(check.title)
                        Spacer()
                        Text("\(check.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(check.detail)
                }
            }
        }
    }

    /// Says what kind of trouble the library is in before listing it, because
    /// "9 findings" reads the same whether they are all cosmetic or one of them
    /// means the graph is wrong.
    private var headline: String {
        let defects = checks.filter(\.isDefect)
        if defects.isEmpty {
            return "Nothing is broken. \(checks.count) finding\(checks.count == 1 ? "" : "s") about work not yet done."
        }
        let records = defects.reduce(0) { $0 + $1.count }
        return "\(defects.count) thing\(defects.count == 1 ? "" : "s") wrong, across \(records) record\(records == 1 ? "" : "s")."
    }

    @ViewBuilder
    private func fixRow(for check: StudioCheck) -> some View {
        switch availability(of: check.fix) {
        case let .available(label):
            Button {
                onFix(check.fix)
                dismiss()
            } label: {
                Label(label, systemImage: "arrow.forward.circle")
            }
        case let .notBuilt(label):
            // Named rather than hidden. The finding is real and the tool that
            // will resolve it is decided — saying so beats an unexplained row
            // with no way forward.
            Label("\(label) will resolve this — not built yet",
                  systemImage: "hammer")
                .font(.callout)
                .foregroundStyle(.tertiary)
        case .none:
            Label("No tool resolves this yet — fix it by hand",
                  systemImage: "wrench.adjustable")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private enum Availability {
        case available(String)
        case notBuilt(String)
        case none
    }

    /// The label each destination carries in Settings, so a finding sends you
    /// somewhere you can recognise when you get there.
    private func availability(of fix: StudioFix) -> Availability {
        switch fix {
        case .fixDuplicateStudios:    return .available("Fix Duplicate Studios")
        case .repairTagSpelling:      return .available("Repair Tag Spelling")
        case .connectTheGraph:        return .available("Connect the Graph")
        case .matchAgain:             return .available("Match Again")
        case .removeOrphanedProfiles: return .available("Remove Orphaned Profiles")
        case .matchStudios:           return .available("Match All Studios")
        case .none:                   return .none
        }
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        let result: Result<[StudioCheck], Error> = await Task.detached {
            do { return .success(try LibraryStore(at: url).auditStudios()) }
            catch { return .failure(error) }
        }.value

        switch result {
        case let .success(found): checks = found
        case let .failure(error): failure = error.localizedDescription
        }
        isWorking = false
    }
}
