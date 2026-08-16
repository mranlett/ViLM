// RelocationPlanView.swift
// What a rename WOULD do, read before anything moves (#17, step 3).
//
// 🚨 THE PLAN IS THE SAFETY PROPERTY, NOT A PREVIEW. Renaming in place across
// two thousand files has no copy to fall back on, so the difference between a
// feature and a way to lose a library is whether every step is known before the
// first one runs. A plan nobody can read is not a safety property, which is why
// the mover starts with this screen rather than ending with it.
//
// 🚨 THE PLAN STILL WRITES NOTHING. `relocationPlan()` touches neither the
// database nor the filesystem (F3, asserted by snapshotting both). What has
// changed is that there is now something to run it with: `RelocationMover`
// exists, with its interruption safety (F4) and its reversibility (F5), so the
// Run button that this file previously and deliberately withheld is here.
//
// ⚠️ It appears ONLY when `plan.canRun`. The earlier note said a disabled
// button would imply machinery that did not exist; now that it does, an ABSENT
// button carries the same honesty — a collision is not a thing to be forced
// past, and offering a greyed-out control invites hunting for the override.
//
// ⚠️ Built the same way as Impossible Data and Studio Health: same detached
// scan, same counted-and-said-out-loud truncation, same refusal to invent a
// repair. Three audit screens that behave differently is three things to learn.

import SwiftUI
import LibraryCore

struct RelocationPlanView: View {
    let libraryURL: URL
    /// Opens a video. The parent dismisses this sheet first — presenting one
    /// sheet while another is closing is how the second silently fails.
    var onOpenVideo: (Asset.ID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var plan: RelocationPlan?
    @State private var isWorking = true
    @State private var failure: String?

    // MARK: - Running it (step 3)

    @State private var isConfirmingRun = false
    @State private var isRunning = false
    /// The run just performed, kept so its result can be reported AND undone.
    /// ⚠️ Holds the run id, because F5's revert is addressed by run — undoing
    /// "everything ever moved" would reverse relocations already accepted.
    @State private var lastRun: RelocationRunResult?
    @State private var runFailure: String?
    /// An interrupted run that opening this screen tidied up. Nil when there
    /// was nothing to resolve, so the banner appears only when it has news.
    @State private var recovered: ReconciliationReport?
    /// What the previous run did, read from the journal. ⚠️ Persistent, unlike
    /// `recovered` — it is still true tomorrow, and an interrupted run must not
    /// stop being mentioned the moment it is repaired.
    @State private var previousRun: RelocationRunSummary?

    /// #75 — the sidecar catch-up, and what it last reported.
    @State private var isBackfilling = false
    @State private var backfill: SidecarBackfillSummary?

    /// ⚠️ Whatever is cut is COUNTED and said out loud. A list that quietly
    /// stops reads as a library with only that many files in it.
    private let examplesShown = 12

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Relocation Plan")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Re-check") { Task { await scan() } }
                            .disabled(isWorking || isRunning)
                    }
                    // 🚨 Rename is NOT here. It lives in the content, beside the
                    // count it acts on — see `runButton`.
                    //
                    // ⚠️ It was a conditional `ToolbarItem` and did not appear on
                    // iOS at all. A toolbar does not reliably re-evaluate
                    // conditional content when the state it depends on arrives
                    // asynchronously, and `plan` arrives after `.task` finishes.
                    // macOS happened to survive that; iOS did not, so the one
                    // control that does the work was simply absent on the phone.
                }
                .confirmationDialog("Rename \(plan?.moves.count ?? 0) files?",
                                    isPresented: $isConfirmingRun, titleVisibility: .visible) {
                    Button("Rename \(plan?.moves.count ?? 0) Files") {
                        Task { await run() }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(confirmationMessage)
                }
        }
        .macSheet(minWidth: 760, minHeight: 600)
        .task { await scan() }
    }

    /// ⚠️ Says what is IRREVERSIBLE and what is not, rather than a generic
    /// warning. The rename is reversible by design (F5); the assumed seasons
    /// are the part that encodes a judgement, so they are named here where the
    /// operator is deciding, not left in a footer they have scrolled past.
    private var confirmationMessage: String {
        guard let plan else { return "" }
        var lines = [
            "Files are renamed in place on this volume — nothing is copied, so no "
            + "extra space is needed."
        ]
        if plan.assumedSeasonCount > 0 {
            lines.append("\(plan.assumedSeasonCount) have no season recorded and will be "
                         + "filed under Season 01.")
        }
        lines.append("Every move is recorded before it happens, so an interrupted run "
                     + "leaves no file half-moved, and the whole run can be put back.")
        return lines.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Working out where everything would go…")
        } else if isRunning {
            ProgressView("Renaming…")
        } else if let lastRun {
            runReport(lastRun)
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if let plan {
            report(plan)
        }
    }

    /// What the run actually did, and the way back.
    ///
    /// ⭐ Undo is offered on the SAME screen, immediately. F5 is a property of
    /// the journal rather than of this session — it works tomorrow too — but a
    /// reversible operation whose reverse is hidden somewhere else is one the
    /// operator will not trust enough to use.
    @ViewBuilder
    private func runReport(_ result: RelocationRunResult) -> some View {
        List {
            Section {
                Label("\(result.moved.count) renamed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !result.failed.isEmpty {
                    Label("\(result.failed.count) could not be renamed",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                // ⚠️ Stated even when it is zero-effort news: a run that had to
                // tidy up after an earlier interrupted one did something the
                // operator did not ask for, and should say so.
                if result.reconciled.total > 0 {
                    Text("Before starting, \(result.reconciled.total) unfinished "
                         + "move\(result.reconciled.total == 1 ? "" : "s") from an "
                         + "interrupted run were resolved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Every move was recorded before it happened, and the old paths are "
                     + "kept — this run can be put back exactly as it was.")
            }

            if !result.failed.isEmpty {
                Section("Not renamed") {
                    ForEach(result.failed.prefix(examplesShown), id: \.assetId) { failure in
                        Button {
                            onOpenVideo(failure.assetId)
                            dismiss()
                        } label: {
                            Text(failure.reason)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if result.failed.count > examplesShown {
                        Text("and \(result.failed.count - examplesShown) more")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await undo(runId: result.runId) }
                } label: {
                    Label("Put it all back", systemImage: "arrow.uturn.backward")
                }
                Button("Work out a new plan") {
                    lastRun = nil
                    Task { await scan() }
                }
            } footer: {
                Text("Putting it back restores the previous layout exactly, from the "
                     + "recorded paths — not by working out where each file would go "
                     + "now, which would repeat whatever this run got wrong.")
            }

            if let runFailure {
                Section {
                    Text(runFailure).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func report(_ plan: RelocationPlan) -> some View {
        List {
            // 🚨 An interrupted run that healed itself is still news. Silent
            // recovery would mean files moved between one session and the next
            // with nothing ever saying so — and if any row could NOT be
            // resolved, that is the most important thing on the screen.
            if let recovered {
                Section {
                    if recovered.deferredWhileRunning {
                        Label("A rename is running, so unfinished moves were not checked",
                              systemImage: "hourglass")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !recovered.completed.isEmpty {
                        Label("\(recovered.completed.count) unfinished move\(recovered.completed.count == 1 ? "" : "s") from an earlier run finished",
                              systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !recovered.abandoned.isEmpty {
                        Label("\(recovered.abandoned.count) never started and were dropped",
                              systemImage: "minus.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !recovered.isClean {
                        Label("\(recovered.missing.count + recovered.ambiguous.count) could not be resolved automatically",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Label(recovered.deferredWhileRunning
                          ? "Not checked yet" : "Recovered from an interrupted run",
                          systemImage: recovered.deferredWhileRunning ? "hourglass" : "bandage")
                } footer: {
                    Text(recovered.deferredWhileRunning
                         ? "A rename is still in progress, so this screen has not looked for unfinished moves — a running rename leaves rows that look exactly like interrupted ones. Re-check once it has finished."
                         : recovered.isClean
                         ? "A previous run was stopped partway. Every file it had started to move has been put into a settled state, and the plan below reflects that."
                         : "A previous run was stopped partway and some files are at neither their old nor their new path. Nothing further will run until those are sorted out — the record of where each was going has been kept.")
                }
            }

            // 🚨 The previous run, stated every time — not only on the open that
            // happened to repair something. An interrupted run leaves work
            // behind, and without this the screen shows a plan with moves in it
            // and nothing anywhere saying the last attempt stopped early.
            if let previousRun, previousRun.moved > 0 {
                Section {
                    Label("\(previousRun.moved) file\(previousRun.moved == 1 ? "" : "s") renamed",
                          systemImage: previousRun.wasInterrupted
                            ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(previousRun.wasInterrupted ? .orange : .secondary)

                    if previousRun.wasInterrupted {
                        Text("That run did not finish. \(previousRun.recovered) file\(previousRun.recovered == 1 ? " was" : "s were") moved without the library recording it, and \(previousRun.unresolved > 0 ? "\(previousRun.unresolved) still need looking at" : "have now been put right").")
                            .font(.caption)
                    }
                    if plan.canRun {
                        Text("\(plan.moves.count) still to move.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Your last run", systemImage: "clock.arrow.circlepath")
                } footer: {
                    Text(previousRun.wasInterrupted
                         ? "A run stops if the app is closed or backgrounded partway through. Nothing is lost when that happens — running again picks up whatever is left."
                         : "Running again picks up anything newly declared since.")
                }
            }

            Section {
                Text(plan.headline()).font(.callout)
                Text(verdict(for: plan))
                    .font(.callout)
                    .foregroundStyle(plan.canRun ? Color.primary : .secondary)

                // ⭐ The action sits with the sentence describing it, on both
                // platforms, rather than in a nav bar where iOS lost it.
                if plan.canRun {
                    Button {
                        isConfirmingRun = true
                    } label: {
                        Label("Rename \(plan.moves.count) File\(plan.moves.count == 1 ? "" : "s")",
                              systemImage: "arrow.right.doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            } footer: {
                // 🚨 Said once, plainly, at the top. The whole screen is a
                // promise that nothing has happened yet.
                Text("Nothing has moved and nothing here will move it — working out the plan does not touch a single file. Renaming is the next piece of work, and it will not start without this plan being clean first.")
            }

            // ⚠️ FIRST, because it is the only thing that BLOCKS. Two videos
            // wanting one path is ordinary — a studio with two undated scenes
            // and the same cast produces it — and the answer is to report the
            // pair, never to let one silently overwrite the other.
            if !plan.collisions.isEmpty {
                Section {
                    ForEach(plan.collisions.prefix(examplesShown)) { collision in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(collision.target)
                                .font(.caption.monospaced())
                                .lineLimit(2).truncationMode(.middle)
                            ForEach(Array(collision.titles.enumerated()), id: \.offset) { _, title in
                                Text("· \(title)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    if plan.collisions.count > examplesShown {
                        Text("and \(plan.collisions.count - examplesShown) more")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                } header: {
                    label("Two videos want the same name",
                          count: plan.collisions.count,
                          icon: "exclamationmark.octagon.fill", tint: .red)
                } footer: {
                    Text("Nothing can be renamed while any of these remain: one file would overwrite the other. Give one of each pair something the name can tell apart — a release date, or a different title.")
                }
            }

            // The work list. ⭐ Grouped by REASON and counted, because
            // "1,900 need declaring" is a task and 1,900 rows is not.
            if !plan.unfilable.isEmpty {
                Section {
                    ForEach(plan.unfilableByReason, id: \.reason) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.reason)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text("\(row.count)")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    label("Cannot be filed yet", count: plan.unfilable.count,
                          icon: "tray", tint: .orange)
                } footer: {
                    Text(unfilableAdvice(plan))
                }

                Section("Examples") {
                    ForEach(plan.unfilable.prefix(examplesShown)) { video in
                        Button {
                            onOpenVideo(video.assetId)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.title)
                                    .font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(video.skip.reason)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if plan.unfilable.count > examplesShown {
                        Text("and \(plan.unfilable.count - examplesShown) more")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }

            if !plan.moves.isEmpty {
                Section {
                    ForEach(plan.moves.prefix(examplesShown)) { move in
                        Button {
                            onOpenVideo(move.assetId)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(move.from)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                    Text(move.to)
                                        .font(.caption.monospaced())
                                        .lineLimit(2).truncationMode(.middle)
                                }
                                // ⚠️ Marked on the row, not only totalled above.
                                // Agreeing to "204 assumed seasons" in aggregate
                                // is not the same as being able to see WHICH.
                                if move.assumedSeason {
                                    Label("Season 01 assumed", systemImage: "questionmark.circle")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if plan.moves.count > examplesShown {
                        Text("and \(plan.moves.count - examplesShown) more")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                } header: {
                    label("Would be renamed", count: plan.moves.count,
                          icon: "arrow.right.doc.on.clipboard", tint: .accentColor)
                } footer: {
                    // 🚨 The assumption is stated in the dry run, where it can
                    // still be disagreed with. A season nobody declared, applied
                    // to two hundred files and noticed afterwards, is exactly
                    // the quiet wrongness this screen exists to prevent.
                    Text(plan.assumedSeasonCount > 0
                         ? "Every one of these is shown before anything runs, and the old path is recorded so the whole layout can be put back.\n\n\(plan.assumedSeasonCount) of them have no season recorded and will be filed under Season 01. That is a filing convention, not a claim — nothing is written to the video itself, so stating a real season later changes only where it goes."
                         : "Every one of these is shown before anything runs, and the old path is recorded so the whole layout can be put back.")
                }
            }

            if plan.alreadyInPlace > 0 {
                Section {
                    HStack {
                        Text("Already named correctly")
                        Spacer()
                        Text("\(plan.alreadyInPlace)").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } footer: {
                    // Counted so that "nothing to do" is distinguishable from
                    // "nothing was examined" — two very different answers.
                    Text("Counted so that a plan with no moves is not mistaken for a library that was never looked at.")
                }
            }

            sidecarBackfillSection
        }
    }

    /// #75 — the sidecar catch-up for files renamed before sidecars existed.
    ///
    /// ⭐ It lives on this screen because this is where the renaming happened,
    /// and the gap it fills was created by a rename. Putting it in Settings
    /// would separate the repair from the thing that needs repairing.
    ///
    /// ⚠️ In the CONTENT, not a toolbar — the button appears beside the
    /// sentence describing it, on both platforms, for the same reason the Run
    /// button does.
    @ViewBuilder
    private var sidecarBackfillSection: some View {
        Section {
            Button {
                Task { await backfillSidecars() }
            } label: {
                Label("Write Missing Sidecars", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBackfilling || isRunning)
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))

            if let result = backfill {
                // 🚨 Every bucket is shown, including the ones that did
                // nothing. "Wrote 40" over a library of 254 reads as 214
                // failures unless the screen says why the rest were left.
                summaryRow("Written", result.written)
                if result.alreadyPresent > 0 { summaryRow("Already had one", result.alreadyPresent) }
                if result.refused > 0 { summaryRow("Personal or undeclared — none written", result.refused) }
                if result.failed > 0 { summaryRow("Could not be written", result.failed) }

                // 🚨 The one finding worth interrupting for.
                if result.refusedButPresent > 0 {
                    Label("\(result.refusedButPresent) personal or undeclared video\(result.refusedButPresent == 1 ? " has a sidecar" : "s have sidecars") beside them. Nothing here wrote or removed those — they name people in plain text on a drive that travels.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Sidecars")
        } footer: {
            Text("A sidecar is written when a video is renamed, so videos renamed before that existed have none. This writes one for any video missing it, and never touches a video that already has one — running it twice costs nothing. Personal and undeclared videos are deliberately skipped.")
        }
    }

    private func summaryRow(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func backfillSidecars() async {
        isBackfilling = true
        defer { isBackfilling = false }
        let url = libraryURL
        backfill = await Task.detached(priority: .utility) { () -> SidecarBackfillSummary? in
            guard let store = try? LibraryStore(at: url),
                  let assets = try? store.fetchAllAssets() else { return nil }
            let profiles = (try? store.fetchAllEntityProfiles()).map(EntityProfileIndex.init)
            return SidecarBackfill.run(libraryURL: url, assets: assets, profiles: profiles)
        }.value
    }

    // MARK: - What the numbers mean

    /// The one sentence that says whether this could run, and if not, why not.
    ///
    /// ⭐ The DECISION is `plan.readiness`, in LibraryCore and under test. Only
    /// the wording lives here. The first draft worked this out in the view, in
    /// a private function no test could reach — which is precisely the shape of
    /// the defect logged on 2026-08-14, and it was not going to be repeated in
    /// the same week.
    private func verdict(for plan: RelocationPlan) -> String {
        switch plan.readiness {
        case let .blocked(collisions):
            return "Blocked: \(collisions) name\(collisions == 1 ? "" : "s") would be claimed by more than one video."
        case .nothingToDo:
            return "Every video is already where it belongs."
        case .allWaiting:
            return "Nothing can be renamed yet — every video is waiting on something below."
        case let .ready(moves):
            return "Ready: \(moves) file\(moves == 1 ? "" : "s") could be renamed once the mover is built."
        }
    }

    /// ⭐ Names the ONE thing that would unblock the most files, rather than
    /// leaving the operator to read a table and work it out. On a library
    /// nobody has declared yet, that is the whole list and saying so is the
    /// most useful thing this screen can do.
    private func unfilableAdvice(_ plan: RelocationPlan) -> String {
        let undeclared = plan.undeclaredCount

        if undeclared == plan.unfilable.count && undeclared > 0 {
            return "Every one of these is waiting on the same thing: nothing has been declared. Select videos in All Assets, open the batch inspector and use “What are these?” — declare the bulk as Scene, then pick out the exceptions. Nothing is guessed for you, because a default would be a guess wearing a declaration's clothing."
        }
        if undeclared > 0 {
            return "\(undeclared) of these are simply undeclared — select them in All Assets and use “What are these?”. The rest are missing a field their kind needs, and each row above says which."
        }
        return "Each row says what is missing. A video is left exactly where it is rather than filed under an invented value — a wrong path is harder to notice than a file that visibly waited."
    }

    private func label(_ title: String, count: Int, icon: String, tint: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func scan() async {
        isWorking = true
        failure = nil
        let url = libraryURL
        let result: Result<(RelocationPlan, ReconciliationReport,
                            RelocationRunSummary?), Error> = await Task.detached {
            do {
                let store = try LibraryStore(at: url)
                // 🚨 Reconcile BEFORE planning, and on merely OPENING this
                // screen. Without this the library does not heal itself after
                // an interrupted run: the file has moved, the row still points
                // at the old path, and the video simply reads as missing —
                // with the only cure being to press Rename again, which is not
                // something anyone would think to do about a missing video.
                //
                // ⚠️ It also makes the plan correct. Planning first would read
                // stale paths and propose moving a file that has already gone,
                // which then fails during the run for a reason that has nothing
                // to do with the operator.
                let recovered = try store.reconcileInterruptedRelocations(libraryURL: url)
                return .success((try store.relocationPlan(), recovered,
                                 try store.lastRelocationRun()))
            } catch { return .failure(error) }
        }.value

        switch result {
        case let .success(computed, recoveredReport, lastSummary):
            plan = computed
            // ⚠️ Also kept when reconciliation DECLINED to look (#71) — the
            // difference between "checked and clean" and "did not check" is
            // exactly what a screen must not blur.
            recovered = (recoveredReport.total > 0 || recoveredReport.deferredWhileRunning)
                ? recoveredReport : nil
            previousRun = lastSummary
        case let .failure(error):
            failure = error.localizedDescription
        }
        isWorking = false
    }

    /// Runs the plan that is on screen.
    ///
    /// 🚨 Runs THE PLAN THE OPERATOR READ, not a freshly computed one. Re-planning
    /// here would move files the confirmation dialog never counted — the numbers
    /// they agreed to and the work performed have to be the same thing.
    private func run() async {
        guard let plan else { return }
        isRunning = true
        runFailure = nil
        let url = libraryURL
        // ⚠️ The run id is minted HERE and passed in, rather than inside the
        // mover: it identifies this run for the revert, and a value generated
        // deeper down could not be reported back if the run failed partway.
        let runId = UUID().uuidString

        let outcome: Result<RelocationRunResult, Error> = await Task.detached {
            do {
                let store = try LibraryStore(at: url)
                return .success(try RelocationMover(store: store)
                    .run(plan, libraryURL: url, runId: runId))
            } catch { return .failure(error) }
        }.value

        switch outcome {
        case let .success(result):
            lastRun = result
        case let .failure(error):
            runFailure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isRunning = false
    }

    private func undo(runId: String) async {
        isRunning = true
        runFailure = nil
        let url = libraryURL
        let outcome: Result<RelocationRunResult, Error> = await Task.detached {
            do {
                let store = try LibraryStore(at: url)
                return .success(try RelocationMover(store: store)
                    .revert(runId: runId, libraryURL: url))
            } catch { return .failure(error) }
        }.value

        switch outcome {
        case let .success(result):
            // ⚠️ A partial revert is reported rather than swallowed. Anything
            // that could not go back is exactly what a person needs to see.
            if result.failed.isEmpty {
                lastRun = nil
                await scan()
            } else {
                runFailure = "\(result.moved.count) put back, "
                    + "\(result.failed.count) could not be — "
                    + (result.failed.first?.reason ?? "")
            }
        case let .failure(error):
            runFailure = error.localizedDescription
        }
        isRunning = false
    }
}
