// StaleMatchAuditView.swift
// Matches the source says are gone or moved (#49, #50).
//
// 🔴 REPORT, NEVER REPAIR — but not "never act". The distinction is the whole
// screen. Nothing here changes on its own and there is no bulk button; every
// row waits for the operator, because an upstream deletion is evidence about
// the SOURCE's records, not an instruction about ours.
//
// ⚠️ Its own screen rather than a section of *Impossible Data*, whose stated
// contract is that no button on it fixes anything. These findings DO have
// actions, and mixing the two would break a promise the other screen makes in
// its own footer.
//
// ⭐ Two actions, and which one is offered is decided by the source, not by the
// operator guessing. A merge knows where it went and can be re-pointed in one
// tap; a deletion needs a decision. Offering "clear" for a merge would throw
// away an identity the source has already told us how to keep.

import SwiftUI
import LibraryCore

struct StaleMatchAuditView: View {
    let libraryURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var findings: [StaleMatchFinding] = []
    @State private var isWorking = true
    @State private var failure: String?
    @State private var pendingClear: StaleMatchFinding?

    /// The active re-check.
    ///
    /// 🚨 Without this the screen cannot ever say anything. The audit reads
    /// flags earlier fetches happened to persist — so on a library where no
    /// fetch has run since the feature shipped, it reports "nothing missing"
    /// permanently, and the operator has no way to tell that from good news.
    ///
    /// ⚠️ Deliberately NOT automatic on open. It is one request per matched
    /// record — hundreds — and a screen that quietly spends that because
    /// someone looked at it is a screen people stop opening.
    @State private var checkTask: Task<Void, Never>?
    @State private var checked = 0
    @State private var toCheck = 0
    @State private var checkNote: String?

    private var isChecking: Bool { checkTask != nil }

    private var actorProvider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installedActorProviders().first
    }
    private var videoProvider: (any VideoMetadataProvider)? {
        PluginEnvironment.registry.installedVideoProviders().first
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Gone at the Source")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if isChecking {
                            Button("Stop") { checkTask?.cancel() }
                        } else {
                            Button("Check now") { checkNow() }
                                .disabled(isWorking
                                          || (actorProvider == nil && videoProvider == nil))
                        }
                    }
                }
        }
        .macSheet(minWidth: 720, minHeight: 580)
        .task { await scan() }
        // ⚠️ A real two-way binding, not `.constant`. Dismissing by tapping
        // away sets it false, and a constant binding would ignore that and
        // leave the dialog stuck open with no way back.
        .confirmationDialog("Clear this match?",
                            isPresented: Binding(get: { pendingClear != nil },
                                                 set: { if !$0 { pendingClear = nil } }),
                            titleVisibility: .visible) {
            Button("Clear the match", role: .destructive) {
                if let finding = pendingClear { act(.clear, on: finding) }
                pendingClear = nil
            }
            Button("Keep it", role: .cancel) { pendingClear = nil }
        } message: {
            // ⚠️ Says what is kept, not only what goes. The operator is being
            // asked to discard an identity they may have confirmed by hand.
            Text("\(pendingClear?.displayName ?? "This record") stays in your library with everything you have recorded about it. Only the link to the source is removed, and the old identifier is kept so this stays explainable later.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isChecking {
            VStack(spacing: 10) {
                ProgressView(value: Double(checked), total: Double(max(toCheck, 1)))
                    .frame(maxWidth: 280)
                Text("Asking the source about \(checked) of \(toCheck)…")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Stop at any point — what has been checked stays checked.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isWorking {
            ProgressView("Reading what the source last said…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if findings.isEmpty {
            ContentUnavailableView {
                Label("Nothing is missing upstream", systemImage: "checkmark.seal")
            } description: {
                // 🚨 Distinguishes "all fine" from "never asked", and says how
                // to move from the second to the first. The old wording stated
                // the distinction and then left the operator with no way to act
                // on it — so an empty screen looked like a broken feature.
                VStack(spacing: 10) {
                    Text(checkNote
                         ?? "Nothing here has been asked about yet. This screen reads what earlier lookups recorded, and a match nobody has looked up since is neither missing nor confirmed — it is simply unknown.")
                    if actorProvider != nil || videoProvider != nil {
                        Button("Check now") { checkNow() }
                            .buttonStyle(.borderedProminent)
                        Text("Asks the source about every match this library holds — one request each, so it takes a while. You can stop at any point and keep what it found.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Text(StaleMatchAudit.headline(findings)).font(.callout)
                if let checkNote {
                    Text(checkNote).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Nothing here has been changed. A record the source MOVED can be re-pointed in one tap — the source says where it went. A record the source REMOVED needs your decision, because upstream deletions happen for reasons that have nothing to do with your library.")
            }

            ForEach(findings) { finding in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.displayName)
                            .font(.callout)
                            .lineLimit(1).truncationMode(.middle)
                        Text(subtitle(for: finding))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    switch finding.kind {
                    case let .merged(into):
                        Button {
                            act(.rePoint(to: into), on: finding)
                        } label: {
                            Label("Re-point to the record it moved to",
                                  systemImage: "arrow.turn.down.right")
                        }
                    case .deleted:
                        Button(role: .destructive) {
                            pendingClear = finding
                        } label: {
                            Label("Clear the match", systemImage: "link.badge.plus")
                                .symbolVariant(.slash)
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: finding.isMerge
                              ? "arrow.triangle.branch" : "questionmark.folder")
                            // ⭐ A merge is not a problem — it is an answer.
                            // Dressing it in the same red as a deletion would
                            // teach the operator to dread the whole screen.
                            .foregroundStyle(finding.isMerge ? Color.accentColor : .orange)
                        Text(finding.isMerge ? "Moved" : "No longer at the source")
                        Spacer()
                        Text(finding.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func subtitle(for finding: StaleMatchFinding) -> String {
        var line = "was \(finding.sourceId)"
        if let seen = finding.seenAt {
            line += " — seen \(seen.formatted(date: .abbreviated, time: .omitted))"
        }
        return line
    }

    private enum Action {
        case rePoint(to: String)
        case clear
    }

    /// ⚠️ Re-scans afterwards rather than removing the row locally. The store
    /// is the only thing that knows whether the write landed, and a row that
    /// vanishes optimistically would hide a failure.
    private func act(_ action: Action, on finding: StaleMatchFinding) {
        let url = libraryURL
        Task {
            let result: Error? = await Task.detached {
                do {
                    let store = try LibraryStore(at: url)
                    // 🚨 Taken from the finding, never inferred from the id.
                    // Both kinds are UUID strings, so guessing would send every
                    // actor's finding to the video table — matching nothing and
                    // reporting success.
                    let isVideo = finding.isVideo
                    switch action {
                    case let .rePoint(to):
                        try store.rePointMatch(nodeId: finding.nodeId, source: finding.source,
                                               isVideo: isVideo, to: to)
                    case .clear:
                        try store.clearStaleMatch(nodeId: finding.nodeId,
                                                  source: finding.source, isVideo: isVideo)
                    }
                    return nil
                } catch { return error }
            }.value

            if let result { failure = result.localizedDescription }
            await scan()
        }
    }

    /// Asks the source about every match this library holds.
    ///
    /// ⭐ Records the answer for EVERY record, not only the missing ones. A
    /// `checkedAt` on a healthy match is what turns "nothing missing" from a
    /// statement about our ignorance into one about the source.
    ///
    /// ⚠️ Sequential. The shared client enforces the plugin's declared rate
    /// limit, and firing hundreds at once is how that limit gets discovered the
    /// hard way. Cancellable, and what has been recorded stays recorded.
    ///
    /// 🔴 A failed fetch records NOTHING and moves on. That is the U2 rule at
    /// its most load-bearing: a sweep over a dropped connection would otherwise
    /// mark the entire library deleted in one pass.
    private func checkNow() {
        guard !isChecking else { return }
        let url = libraryURL
        checkNote = nil
        checkTask = Task {
            defer { checkTask = nil }
            do {
                let store = try LibraryStore(at: url)
                var targets: [RecheckTarget] = []
                if let name = actorProvider?.displayName ?? videoProvider?.displayName {
                    targets = try store.matchesToRecheck(source: name)
                }
                toCheck = targets.count
                checked = 0
                guard !targets.isEmpty else {
                    checkNote = "No match in this library names an installed source, so there is nothing to ask about."
                    return
                }

                var failed = 0
                // 🚨 Counted SEPARATELY from an unreachable one, because they
                // are not the same answer and the difference is the whole
                // open question about this feature.
                //
                // A timeout means the source said nothing. `notFound` means it
                // answered: "I have no record under that id." If the source
                // returns deleted performers as null rather than as records
                // flagged `deleted`, this is the ONLY signal we will ever get —
                // and lumping it in with dropped connections made the feature
                // look permanently, inexplicably empty.
                //
                // ⚠️ Counted, NOT flagged as a deletion. A missing id is still
                // ambiguous between "removed" and "merged away under a new id",
                // and U2's rule is that we do not record a conclusion we have
                // not actually been given. Measure first.
                var notFound = 0
                for target in targets {
                    if Task.isCancelled { break }
                    let state: SourceRecordState?
                    do {
                        if target.isVideo, let provider = videoProvider {
                            state = try await provider.fetch(videoId: target.sourceId).recordState
                        } else if !target.isVideo, let provider = actorProvider {
                            state = try await provider.fetch(actorId: target.sourceId).recordState
                        } else {
                            state = nil
                        }
                    } catch let error as PluginError {
                        // Concluded nothing either way — but WHICH nothing
                        // matters, so the two are counted apart.
                        if case .notFound = error { notFound += 1 } else { failed += 1 }
                        state = nil
                    } catch {
                        failed += 1
                        state = nil
                    }
                    if let state {
                        try? store.recordSourceState(state, nodeId: target.nodeId,
                                                     source: target.isVideo
                                                        ? (videoProvider?.displayName ?? "")
                                                        : (actorProvider?.displayName ?? ""),
                                                     sourceId: target.sourceId,
                                                     isVideo: target.isVideo)
                    }
                    checked += 1
                }
                // ⚠️ Says how many could not be reached. Without it a sweep
                // that failed nine times in ten reads as a clean bill.
                var parts = ["Checked \(checked) of \(toCheck)."]
                if failed > 0 {
                    parts.append("\(failed) could not be reached and were left as they were.")
                }
                if notFound > 0 {
                    // ⭐ Said in full, because this is the number that decides
                    // whether the feature can work at all. If the source
                    // answers "no such record" for matches we hold, that is
                    // where every upstream deletion is hiding.
                    parts.append("\(notFound) returned no record at all under the id we hold — the source may report deletions this way rather than with a flag.")
                }
                checkNote = parts.joined(separator: " ")
            } catch {
                checkNote = "Couldn't re-check: \(error.localizedDescription)"
            }
            await scan()
        }
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        let result: Result<[StaleMatchFinding], Error> = await Task.detached {
            do { return .success(try LibraryStore(at: url).staleMatchFindings()) }
            catch { return .failure(error) }
        }.value

        switch result {
        case let .success(found): findings = found
        case let .failure(error): failure = error.localizedDescription
        }
        isWorking = false
    }
}
