// RelocationPlanView.swift
// What a rename WOULD do, read before anything moves (#17, step 3).
//
// 🚨 THE PLAN IS THE SAFETY PROPERTY, NOT A PREVIEW. Renaming in place across
// two thousand files has no copy to fall back on, so the difference between a
// feature and a way to lose a library is whether every step is known before the
// first one runs. A plan nobody can read is not a safety property, which is why
// the mover starts with this screen rather than ending with it.
//
// 🚨 THIS SCREEN MOVES NOTHING, AND THERE IS NO BUTTON THAT DOES YET. That is
// deliberate and is stated on the screen. `relocationPlan()` writes nothing at
// all (F3, asserted by snapshotting the database and the directory), and the
// mover — with its interruption safety (F4) and its reversibility (F5) — is the
// next piece of work, not this one. A disabled "Run" button would imply the
// machinery exists.
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
                            .disabled(isWorking)
                    }
                }
        }
        .macSheet(minWidth: 760, minHeight: 600)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Working out where everything would go…")
        } else if let failure {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if let plan {
            report(plan)
        }
    }

    private func report(_ plan: RelocationPlan) -> some View {
        List {
            Section {
                Text(plan.headline()).font(.callout)
                Text(verdict(for: plan))
                    .font(.callout)
                    .foregroundStyle(plan.canRun ? Color.primary : .secondary)
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
        }
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
        let result: Result<RelocationPlan, Error> = await Task.detached {
            do { return .success(try LibraryStore(at: url).relocationPlan()) }
            catch { return .failure(error) }
        }.value

        switch result {
        case let .success(computed): plan = computed
        case let .failure(error): failure = error.localizedDescription
        }
        isWorking = false
    }
}
