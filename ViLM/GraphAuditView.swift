// GraphAuditView.swift
// Data that is wrong, found by joining records that disagree.
//
// The sibling of Studio Health, and deliberately built the same way — same
// ordering rule, same certain-versus-unfinished distinction, same refusal to
// repair anything. Two audit screens that behave differently is two things to
// learn.
//
// ⚠️ What is different is that this one cannot route anywhere. Studio Health
// names the tool that fixes each finding; here there is no tool, because the
// audit cannot know WHICH of the two records is wrong. It opens the video and
// lets the operator decide.

import SwiftUI
import LibraryCore

struct GraphAuditView: View {
    let libraryURL: URL
    /// Opens a video. The parent dismisses this sheet first — presenting one
    /// sheet while another is closing is how the second silently fails.
    var onOpenVideo: (Asset.ID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var checks: [GraphCheck] = []
    @State private var isWorking = true
    @State private var failure: String?

    /// ⚠️ Whatever is cut is COUNTED and said out loud. A list that quietly
    /// stops reads as a library with only that many problems.
    private let examplesShown = 15

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Impossible Data")
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
        .macSheet(minWidth: 720, minHeight: 580)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Cross-checking records…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if checks.isEmpty {
            ContentUnavailableView {
                Label("Nothing contradicts itself", systemImage: "checkmark.seal")
            } description: {
                Text("No video is dated before a credited actor was born, and none falls outside a recorded career. Videos with no release date, and actors with no birth date, can't be cross-checked — so this is a clean bill for what could be checked, not for everything.")
            }
        } else {
            findings
        }
    }

    private var findings: some View {
        List {
            Section {
                Text(headline).font(.callout)
            } footer: {
                // The reason there are no fix buttons, said once.
                Text("Nothing here has been changed, and there is no button that fixes it — each finding means one of two records is wrong, and only you can tell which. Tap a row to open the video.")
            }

            ForEach(checks) { check in
                Section {
                    ForEach(check.findings.prefix(examplesShown)) { finding in
                        Button {
                            onOpenVideo(finding.assetId)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.videoLabel)
                                    .font(.callout)
                                    .lineLimit(1).truncationMode(.middle)
                                Text("\(finding.performer) — \(finding.detail)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if check.count > examplesShown {
                        Text("and \(check.count - examplesShown) more")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                } header: {
                    HStack {
                        Image(systemName: check.isCertain
                              ? "exclamationmark.octagon.fill" : "questionmark.diamond")
                            .foregroundStyle(check.isCertain ? .red : .orange)
                        Text(check.title)
                        Spacer()
                        Text("\(check.count)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(check.detail)
                }
            }
        }
    }

    /// Separates what is certainly broken from what merely disagrees with a
    /// record that may itself be incomplete — "9 findings" reads the same
    /// either way, and they are not the same news.
    private var headline: String {
        let certain = checks.filter(\.isCertain).reduce(0) { $0 + $1.count }
        let suspect = checks.filter { !$0.isCertain }.reduce(0) { $0 + $1.count }

        if certain == 0 {
            return "Nothing impossible. \(suspect) thing\(suspect == 1 ? "" : "s") disagree with a recorded career, which is often the record being incomplete rather than the video being wrong."
        }
        return "\(certain) impossible\(suspect > 0 ? ", and \(suspect) worth checking" : "")."
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        let result: Result<[GraphCheck], Error> = await Task.detached {
            do { return .success(try LibraryStore(at: url).auditGraph()) }
            catch { return .failure(error) }
        }.value

        switch result {
        case let .success(found): checks = found
        case let .failure(error): failure = error.localizedDescription
        }
        isWorking = false
    }
}
