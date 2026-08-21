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
    /// Opens the record behind a row.
    ///
    /// 🚨 Added 2026-08-08. This screen listed 164 records by name and none of
    /// them was reachable — the operator could read the worklist and had no way
    /// into a single item on it. The same defect this app has now fixed three
    /// times, and the rule it keeps breaking is already written down: *a tally
    /// you cannot act on is a dead end.*
    ///
    /// ⚠️ Worse here than elsewhere, because the footer tells the operator to
    /// "open one and use Match Again on its profile" — instructions the screen
    /// itself did not let them follow.
    var onExplore: ((SidebarItem) -> Void)?

    @State private var report: IdentityGapReport?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// The row being matched, WITHOUT leaving this screen.
    ///
    /// 🚨 The whole point. Rows used to dismiss the sheet and navigate away, so
    /// working a list of 144 meant 144 round trips through Settings — open the
    /// list, click a row, fix it, close, Settings, Missing Identities, find
    /// your place, repeat. Reported from the device 2026-08-08.
    ///
    /// ⭐ A worklist has to let you work the list.
    @State private var matching: IdentityGap?

    /// What the last repair did, shown until the next one.
    @State private var repairMessage: String?

    /// Names solved during this sitting, so the row goes even before a reload.
    @State private var solved: Set<String> = []

    /// ⚠️ Matched, but the source gave back no identifier — so the edge could
    /// not be written and the row legitimately cannot clear. Recorded per node
    /// because otherwise this looks exactly like the bug that WAS just fixed.
    @State private var matchedWithoutAnId: Set<String> = []

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
        // ⭐ Presented OVER this list, so the list is still there afterwards.
        .sheet(item: $matching) { gap in
            if let provider {
                ActorEnrichmentSheet(
                    provider: provider,
                    entityId: gap.nodeId,
                    actorName: gap.displayName,
                    currentProfile: try? LibraryStore(at: libraryURL)
                        .fetchEntityProfile(for: gap.nodeId),
                    libraryURL: libraryURL,
                    onApply: { merged, _ in
                        // ⚠️ The rename argument is ignored here deliberately.
                        // A global rename rewrites this record's key, and doing
                        // that from inside a worklist would move the very row
                        // the operator is standing on. It stays available on
                        // the profile page, where the consequence is visible.
                        apply(merged, for: gap)
                    })
            }
        }
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
                    if !solved.isEmpty {
                        // ⭐ Progress within the sitting. Working a list of 144
                        // with no visible movement is how a worklist gets
                        // abandoned halfway.
                        Text("\(solved.count) solved just now")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if let repairMessage {
                        Text(repairMessage).font(.caption).foregroundStyle(.secondary)
                    }
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
            ForEach(gaps.filter { !solved.contains($0.nodeId) }.prefix(Self.examplesShown)) { gap in
                Button {
                    // 🚨 A DAMAGED row is not matchable. Its display name is
                    // its own uid, so searching the source for it finds
                    // nothing, and applying a match writes another anonymous
                    // row. It offers Repair instead — see `repairDamaged`.
                    if gap.isDamaged {
                        repairDamaged()
                    }
                    // ⭐ An ACTOR is matched right here, in a sheet over this
                    // one. Only a studio still navigates away, because there is
                    // no equivalent in-place matcher for one yet — and sending
                    // a studio to an actor page finds nothing.
                    else if gap.kind == .actor, provider != nil {
                        matching = gap
                    } else {
                        onExplore?(gap.kind == .actor
                                   ? .actor(gap.displayName)
                                   : .studio(gap.displayName))
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: gap.isDamaged ? "exclamationmark.triangle.fill"
                              : (gap.kind == .actor ? "person" : "building.2"))
                            .font(.caption2)
                            .foregroundStyle(gap.isDamaged ? AnyShapeStyle(Color.orange)
                                             : AnyShapeStyle(.tertiary))
                            .frame(width: 14)
                        Text(gap.displayName)
                            .font(.callout)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        // ⚠️ Both numbers, because their RATIO is the point: "in 9
                        // videos, 2 matched" says a refresh will reach them and the
                        // other seven still will not be identified by it.
                        Text(gap.matchedVideoCount > 0
                             ? "\(gap.videoCount) video\(gap.videoCount == 1 ? "" : "s") · \(gap.matchedVideoCount) matched"
                             : "\(gap.videoCount) video\(gap.videoCount == 1 ? "" : "s")")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        if gap.isDamaged {
                            // ⚠️ Says what it is. Left unexplained this reads
                            // as a performer with a bizarre name, and the
                            // operator re-matches it forever.
                            Text("no name — tap to repair")
                                .font(.caption2).foregroundStyle(.orange)
                        } else if matchedWithoutAnId.contains(gap.nodeId) {
                            // ⚠️ Said on the row. Without this it looks
                            // identical to the defect where a match simply
                            // failed to record — and the operator would keep
                            // re-matching something that can never clear.
                            Text("no id from source")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    /// The installed actor plugin, or nil when none is configured.
    private var provider: (any ActorMetadataProvider)? {
        PluginEnvironment.registry.installedActorProviders().first
    }

    /// Saves a hand-made match and records the EDGE, then clears the row.
    ///
    /// 🚨 The edge is the whole point. Writing only `enrichmentSourceId` is the
    /// defect that made this screen unfixable — the column said matched, the
    /// graph held nothing, and the row survived every attempt.
    private func apply(_ profile: EntityProfile, for gap: IdentityGap) {
        do {
            let store = try LibraryStore(at: libraryURL)
            // ⭐ The one entry point: saves AND records the edge. Writing the
            // column by hand here is what made three screens each report a
            // match the graph did not hold.
            let outcome = try store.applyReviewedMatch(
                profile, source: provider?.displayName, recordingUnder: gap.nodeId)

            guard outcome == .recorded else {
                // ⚠️ Matched with nothing to look it up by. The row STAYS, and
                // is labelled, because it genuinely is not solved.
                matchedWithoutAnId.insert(gap.nodeId)
                return
            }
            solved.insert(gap.nodeId)
            matchedWithoutAnId.remove(gap.nodeId)
            NotificationCenter.default.post(
                name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch {
            errorMessage = "Couldn't record the match: \(error.localizedDescription)"
        }
    }

    /// Restores identity to rows minted without one.
    ///
    /// ⭐ Repairs every damaged row it can name, not just the tapped one. They
    /// arrive in batches — one video's cast at a time — and asking the operator
    /// to tap eleven identical rows in turn is busywork the library can do for
    /// itself.
    ///
    /// ⚠️ Repairs only what it can recover from a crediting video's cast. A row
    /// with no edge, or whose videos disagree, stays listed and stays untouched;
    /// guessing an identity is what caused this in the first place.
    private func repairDamaged() {
        let url = libraryURL
        Task {
            let outcome: Result<Int, Error> = await Task.detached(priority: .utility) {
                do { return .success(try LibraryStore(at: url).repairNamelessNodes()) }
                catch { return .failure(error) }
            }.value

            switch outcome {
            case let .success(count):
                repairMessage = count == 0
                    ? "Nothing could be repaired automatically — these rows have no video crediting them by a name that isn't already taken."
                    : "Recovered \(count) name\(count == 1 ? "" : "s") from the videos crediting them."
            case let .failure(error):
                repairMessage = "Couldn't repair: \(error.localizedDescription)"
            }
            await load()
        }
    }

    private func load() async {
        do {
            let url = libraryURL
            // ⭐ Which source names are the app's. Anything else was typed by
            // the operator (#79), and a record they verified by hand is not a
            // gap — it is `matched` with no edge BY DESIGN, because there is no
            // queryable record behind it. Read on the main actor; the registry
            // is not the detached task's to touch.
            let providers = Set(PluginEnvironment.registry.installed.compactMap {
                ($0 as? any ActorMetadataProvider)?.displayName
                    ?? ($0 as? any StudioMetadataProvider)?.displayName
                    ?? ($0 as? any VideoMetadataProvider)?.displayName
            })
            let found = try await Task.detached(priority: .utility) {
                try LibraryStore(at: url).identityGaps(knownProviders: providers)
            }.value
            await MainActor.run {
                self.report = found
                // A fresh audit supersedes this sitting's bookkeeping.
                self.solved.removeAll()
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
