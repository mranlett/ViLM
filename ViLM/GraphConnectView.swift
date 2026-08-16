// GraphConnectView.swift
// Turns the legacy `actor:` / `studio:` / `tag:` strings into real graph edges.
//
// This is the screen the whole edge migration waits behind: everything the
// store can do — connecting, verifying, reporting what is blocked — was
// unreachable until something called it.
//
// ⚠️ NON-DESTRUCTIVE. The strings are read, never written and never removed.
// Running this changes what the graph CAN answer, not what it says, which is
// why it is safe to run repeatedly and safe to stop after.
//
// Shows the plan before it does anything, because the interesting output is
// not the number connected — it is what CANNOT be connected and why. A credit
// naming someone with no profile, a video the strings gave two studios, a tag
// nobody has classified: each is skipped and named rather than guessed at.
//
// Single library only. Edges live inside one database and reference rows in
// it, so there is no meaning to an edge that spans two.

import SwiftUI
import LibraryCore

struct GraphConnectView: View {
    let libraryURL: URL
    var onFinish: () -> Void
    /// Opens the library filtered to one name or tag.
    ///
    /// 🚨 Added 2026-08-07. Every blocker below was a bare COUNT — "90
    /// performer traits sit on videos", "190 names have no profile" — with no
    /// list and no way through. The operator could read the number and had no
    /// route to a single one of the records behind it.
    ///
    /// The batch runs already state the rule this broke: *a tally you cannot
    /// act on is a dead end.*
    var onExplore: ((SidebarItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// What a dry run says would happen, or what an applied run did.
    private struct Outcome {
        var performers: LibraryStore.ConnectPlan
        var studios: LibraryStore.StudioConnectPlan
        var tags: LibraryStore.TagConnectPlan
    }

    /// Match edges created from the identity columns (v31).
    ///
    /// ⚠️ Folded into this tool rather than given its own button. It is the
    /// same operation — building edges from data the library already holds —
    /// and a migration nobody runs is a migration that did not happen.
    @State private var backfilledMatches = 0
    @State private var plan: Outcome?
    @State private var result: Outcome?
    @State private var edgeCounts: [(GraphEdgeKind, Int)] = []
    /// 🚨 The VIDEOS, not counts.
    ///
    /// `performerEdgeDisagreements()` and `studioEdgeDisagreements()` have
    /// always returned `[UUID]`, and this screen called `.count` on both and
    /// discarded the ids — so it could say "1 videos disagree with their tags"
    /// and offer no way to find the one. A list computed and thrown away, which
    /// is the same defect this screen was already fixed for once.
    @State private var disagreements: (performers: [UUID], studios: [UUID]) = ([], [])
    /// 🚨 The edges behind the disagreement, and the only thing that can close
    /// it. Connecting is `INSERT OR IGNORE` only, so a re-run cannot remove an
    /// edge whose video no longer names it — the operator re-ran the tool,
    /// re-fetched the cast, and watched the count go UP.
    @State private var stale: [LibraryStore.StaleEdge] = []
    @State private var isPruning = false
    @State private var isWorking = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connect the Graph")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(result == nil ? "Cancel" : "Done") { onFinish(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if result == nil, let plan, totalConnectable(plan) > 0 {
                            Button("Connect \(totalConnectable(plan))") {
                                Task { await apply() }
                            }
                            .disabled(isWorking)
                        }
                    }
                }
        }
        .macSheet(minWidth: 720, minHeight: 580)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView("Reading the library…")
        } else if let errorMessage {
            ContentUnavailableView("Couldn't read the library",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorMessage))
        } else if let outcome = result ?? plan {
            List {
                if result != nil { appliedSection }
                connectSection(outcome)
                blockedSection(outcome)
                if result != nil { verificationSection }
            }
        }
    }

    // MARK: - What would happen

    private func connectSection(_ o: Outcome) -> some View {
        Section {
            // ⚠️ NEW edges, with what was already there and what can never
            // be connected stated beside them. The old rows read "484 of
            // 2,596" for a run that created 3 — the numerator was a
            // subtraction across two unrelated sets and the denominator
            // included credits that could never become edges.
            edgeRow("Cast credits",
                    new: o.performers.connectable,
                    already: o.performers.alreadyConnected,
                    skipped: o.performers.skippedNoProfile)
            edgeRow("Studios",
                    new: o.studios.connectable,
                    already: o.studios.alreadyConnected,
                    skipped: o.studios.skippedNoProfile)
            edgeRow("Tags on videos",
                    new: o.tags.newVideoEdges,
                    already: o.tags.videoEdges - o.tags.newVideoEdges,
                    skipped: 0)
            edgeRow("Tags on performers",
                    new: o.tags.newPerformerEdges,
                    already: o.tags.performerEdges - o.tags.newPerformerEdges,
                    skipped: 0)
        } header: {
            Text(result == nil ? "Would connect" : "Connected")
        } footer: {
            Text("“New” is what this run adds. “Already” was connected by an earlier run — re-running is cheap and changes nothing. “Skipped” can never be connected as things stand, and the reasons are below.\n\nThe existing tags are left exactly as they are. This adds a second, structured copy the app can query — it does not remove the first.")
        }
    }

    // MARK: - ⚠️ What would not, and why

    @ViewBuilder
    private func blockedSection(_ o: Outcome) -> some View {
        let hasBlockers = !o.performers.missingProfiles.isEmpty
            || !o.studios.conflicted.isEmpty
            || o.tags.pending > 0
            || !o.tags.attributeTagsOnVideos.isEmpty
            || !o.tags.unknownTags.isEmpty

        if hasBlockers {
            Section {
                if !o.performers.missingProfiles.isEmpty {
                    blocker("\(o.performers.missingProfiles.count) names have no profile",
                            detail: "Their credits are skipped. Creating a person from a name that a filename may have guessed is the one thing the parser is not allowed to do, so it is not done here either — match those videos and the profiles arrive with them.",
                            icon: "person.crop.circle.badge.questionmark",
                            // Filtering by the NAME still works without a
                            // profile: the grid matches the `actor:` string.
                            entries: o.performers.missingProfiles.sorted().map {
                                ($0, SidebarItem.actor($0))
                            })
                }
                if !o.studios.conflicted.isEmpty {
                    blocker("\(o.studios.conflicted.count) videos carry two studios",
                            detail: "A scene has one releasing studio, so these cannot be represented and are skipped rather than one being picked for you. Fix Duplicate Studios resolves them.",
                            icon: "building.2")
                }
                if o.tags.pending > 0 {
                    blocker("\(o.tags.pending) tag links are waiting on a classification",
                            detail: "Held, not lost. Classify the tag and they become edges.",
                            icon: "clock")
                }
                if !o.tags.attributeTagsOnVideos.isEmpty {
                    blocker("\(o.tags.attributeTagAssociations) performer traits sit on videos",
                            detail: "A video isn't a tall — a performer is. These are left alone for enrichment to correct per performer, because which of the cast a trait describes is a guess. Open one to see exactly which videos carry it.",
                            icon: "person.and.arrow.left.and.arrow.right",
                            entries: traitEntries(o.tags.attributeTagsOnVideos))
                }
                if !o.tags.unknownTags.isEmpty {
                    blocker("\(o.tags.unknownTags.count) tags are not in the vocabulary",
                            detail: "Reported rather than created, so promoting and connecting stay separately checkable. Classify Tags adds them.",
                            icon: "questionmark.circle",
                            entries: o.tags.unknownTags.sorted().map {
                                ($0, SidebarItem.tag($0))
                            })
                }
            } header: {
                Text("Skipped")
            } footer: {
                Text("Nothing here is an error. Each is something the graph refuses to guess at, left for a person to decide.")
            }
        }
    }

    // MARK: - Proof it worked

    @ViewBuilder
    private var appliedSection: some View {
        Section {
            ForEach(edgeCounts, id: \.0) { kind, count in
                LabeledContent(label(for: kind), value: "\(count)")
            }
            if backfilledMatches > 0 {
                LabeledContent("external identities", value: "\(backfilledMatches)")
            }
        } header: {
            Text("The graph now holds")
        } footer: {
            if backfilledMatches > 0 {
                // ⭐ Said plainly because it is a one-off: these were recorded
                // as a column on each record and are now edges, which is what
                // lets the library say which nodes have NO identity at all.
                Text("The identities were already on your records; they are now part of the graph, so a node with none is findable rather than merely null.")
            }
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        Section {
            // ⚠️ Checked per video, not by totals: a migration that connected
            // the right NUMBER of things to the wrong videos would pass a count.
            if disagreements.performers.isEmpty && disagreements.studios.isEmpty {
                Label("Every video's edges match its tags", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                // ⚠️ Each kind is its OWN way in, because the two mean
                // different things: a cast disagreement and a studio
                // disagreement are investigated differently, and merging them
                // into one number hid both.
                if !disagreements.performers.isEmpty {
                    disagreementRow("cast", disagreements.performers)
                }
                if !disagreements.studios.isEmpty {
                    disagreementRow("studio", disagreements.studios)
                }
            }
            if !stale.isEmpty { staleEdgeRepair }
        } header: {
            Text("Verification")
        } footer: {
            Text("Compared one video at a time. Matching totals would not prove the right things were connected to the right videos.")
        }
    }

    /// ⭐ The repair, because detecting something nothing can fix is worse than
    /// not detecting it. Connecting only ever INSERTS, so an edge whose video
    /// stopped naming it survives every re-run — and re-fetching a cast adds
    /// the new edges while leaving the old, which makes the number grow.
    @ViewBuilder
    private var staleEdgeRepair: some View {
        let safe = stale.filter(\.videoNamesOthers)
        let needsAPerson = stale.filter { !$0.videoNamesOthers }

        VStack(alignment: .leading, spacing: 6) {
            Text("Why re-running does not clear this")
                .font(.callout)
            Text("Connecting only ever ADDS edges. When a video's cast changes, the edge for who WAS in it stays — so the graph says one thing and the tags say another, and running this tool again cannot remove it. Re-fetching a cast makes it worse, not better.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(safe) { edge in
                Text("\(edge.displayName) — \(edge.fileName)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            if !safe.isEmpty {
                Button(isPruning ? "Removing…" : "Remove \(safe.count) leftover edge\(safe.count == 1 ? "" : "s")") {
                    Task { await prune(safe) }
                }
                .disabled(isPruning)
            }

            if !needsAPerson.isEmpty {
                // ⚠️ A DIFFERENT case, kept apart. These sit on videos naming no
                // cast at all, so the strings may be missing rather than the
                // edge wrong — removing would destroy the only remaining record
                // of who is in the video.
                Text("⚠️ \(needsAPerson.count) more sit on videos with no cast listed at all. Those are not offered here: the tags may be missing rather than the edge wrong, and removing them would delete the only record of who is in the video. Open one and set its cast.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func prune(_ edges: [LibraryStore.StaleEdge]) async {
        isPruning = true
        do {
            let url = libraryURL
            try await Task.detached(priority: .utility) {
                let store = try LibraryStore(at: url)
                // ⭐ Exactly the edges listed above, not a fresh scan. The
                // operator approved a list; deleting something else is not a
                // defensible outcome for a destructive action.
                _ = try store.pruneStaleEdges(edges)
            }.value
            let store = try LibraryStore(at: url)
            disagreements = (try store.performerEdgeDisagreements(),
                             try store.studioEdgeDisagreements())
            stale = try store.staleEdges()
        } catch {
            errorMessage = error.localizedDescription
        }
        isPruning = false
    }

    /// One disagreement kind, as a way IN to the videos behind it.
    @ViewBuilder
    private func disagreementRow(_ kind: String, _ ids: [UUID]) -> some View {
        let title = "\(ids.count) video\(ids.count == 1 ? "" : "s") disagree\(ids.count == 1 ? "s" : "") "
            + "with their \(kind) tags"
        if let onExplore {
            Button {
                onExplore(.videoSet("\(kind.capitalized) disagreements", ids))
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Label(title, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Image(systemName: "arrow.forward.circle").font(.caption2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Label(title, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Pieces

    /// One edge kind: what this run adds, what was already there, and what
    /// cannot be connected at all.
    ///
    /// 🚨 Three numbers because there are three, and collapsing them into
    /// "N of M" produced a figure that matched nothing — reported from the
    /// device, 2026-08-07.
    private func edgeRow(_ title: String, new: Int, already: Int, skipped: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                Text("\(new) new").foregroundStyle(new == 0 ? .secondary : .primary)
            }
            Text(skipped > 0
                 ? "\(already) already connected · \(skipped) skipped"
                 : "\(already) already connected")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func countRow(_ title: String, _ value: Int, of total: Int?) -> some View {
        LabeledContent(title) {
            if let total, total != value {
                Text("\(value) of \(total)").foregroundStyle(value == 0 ? .secondary : .primary)
            } else {
                Text("\(value)").foregroundStyle(value == 0 ? .secondary : .primary)
            }
        }
    }

    /// One row per trait, each opening the EXACT videos carrying it.
    ///
    /// 🚨 `.videoSet`, not `.tag`. The tag page also matches every video whose
    /// CAST carries the trait, so "Redhead — 11 videos" opened onto several
    /// hundred and the operator had to hunt for the eleven. Reported from the
    /// device, 2026-08-08 — and the second time this screen has linked to
    /// something adjacent to the problem rather than the problem.
    ///
    /// Hoisted out of the body because the expression defeated the type
    /// checker inline, which is a recurring cost in this file.
    private func traitEntries(_ byTag: [String: [UUID]]) -> [(label: String, item: SidebarItem?)] {
        let ordered = byTag.sorted { a, b in
            a.value.count != b.value.count
                ? a.value.count > b.value.count
                : a.key < b.key
        }
        return ordered.map { tag, ids in
            let label = "\(tag) — \(ids.count) video\(ids.count == 1 ? "" : "s")"
            return (label, SidebarItem.videoSet(tag, ids))
        }
    }

    private func blocker(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.callout)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// How many examples a blocker lists before it stops.
    ///
    /// ⚠️ Whatever is cut is counted and said out loud — a list that quietly
    /// stops at a dozen reads as a library with a dozen problems.
    private static let examplesShown = 12

    /// A blocker with the records behind it, each one a way in.
    ///
    /// - Parameter item: what to filter the library to. `nil` for entries with
    ///   nowhere sensible to go, which stay plain text rather than pretending
    ///   to be tappable.
    @ViewBuilder
    private func blocker(_ title: String, detail: String, icon: String,
                         entries: [(label: String, item: SidebarItem?)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.callout)
            Text(detail).font(.caption).foregroundStyle(.secondary)

            ForEach(Array(entries.prefix(Self.examplesShown).enumerated()), id: \.offset) { _, entry in
                if let item = entry.item, let onExplore {
                    Button {
                        onExplore(item)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.label).font(.caption)
                            Image(systemName: "arrow.forward.circle")
                                .font(.caption2)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                } else {
                    Text(entry.label).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if entries.count > Self.examplesShown {
                Text("and \(entries.count - Self.examplesShown) more")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func label(for kind: GraphEdgeKind) -> String {
        switch kind {
        case .videoPerformer: return "Video → performer"
        case .videoStudio: return "Video → studio"
        case .videoTag: return "Video → tag"
        case .performerTag: return "Performer → trait"
        case .studioParent: return "Studio → parent"
        case .pendingTagAssociation: return "Waiting on classification"
        }
    }

    private func totalConnectable(_ o: Outcome) -> Int {
        o.performers.connectable + o.studios.connectable + o.tags.videoEdges + o.tags.performerEdges
    }

    // MARK: - Work

    private func scan() async {
        isWorking = true
        do {
            let store = try LibraryStore(at: libraryURL)
            plan = Outcome(performers: try store.connectPerformerEdges(dryRun: true),
                           studios: try store.connectStudioEdges(dryRun: true),
                           tags: try store.connectTagEdges(dryRun: true))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func apply() async {
        isWorking = true
        do {
            let store = try LibraryStore(at: libraryURL)
            result = Outcome(performers: try store.connectPerformerEdges(),
                             studios: try store.connectStudioEdges(),
                             tags: try store.connectTagEdges())
            // Idempotent, and only writes where no edge exists, so re-running
            // this tool adds nothing the second time.
            let filled = try store.backfillMatchEdges()
            backfilledMatches = filled.entities + filled.videos
            edgeCounts = try GraphEdgeKind.allCases.map { ($0, try store.edgeCount($0)) }
            disagreements = (try store.performerEdgeDisagreements(),
                             try store.studioEdgeDisagreements())
            stale = try store.staleEdges()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}
