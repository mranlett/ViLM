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

    @Environment(\.dismiss) private var dismiss

    /// What a dry run says would happen, or what an applied run did.
    private struct Outcome {
        var performers: LibraryStore.ConnectPlan
        var studios: LibraryStore.StudioConnectPlan
        var tags: LibraryStore.TagConnectPlan
    }

    @State private var plan: Outcome?
    @State private var result: Outcome?
    @State private var edgeCounts: [(GraphEdgeKind, Int)] = []
    @State private var disagreements: (performers: Int, studios: Int) = (0, 0)
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
            countRow("Cast credits", o.performers.connectable, of: o.performers.associations)
            countRow("Studios", o.studios.connectable, of: o.studios.associations)
            countRow("Tags on videos", o.tags.videoEdges, of: nil)
            countRow("Tags on performers", o.tags.performerEdges, of: nil)
        } header: {
            Text(result == nil ? "Would connect" : "Connected")
        } footer: {
            Text("The existing tags are left exactly as they are. This adds a second, structured copy the app can query — it does not remove the first.")
        }
    }

    // MARK: - ⚠️ What would not, and why

    @ViewBuilder
    private func blockedSection(_ o: Outcome) -> some View {
        let hasBlockers = !o.performers.missingProfiles.isEmpty
            || !o.studios.conflicted.isEmpty
            || o.tags.pending > 0
            || o.tags.attributeTagsOnVideos > 0
            || !o.tags.unknownTags.isEmpty

        if hasBlockers {
            Section {
                if !o.performers.missingProfiles.isEmpty {
                    blocker("\(o.performers.missingProfiles.count) names have no profile",
                            detail: "Their credits are skipped. Creating a person from a name that a filename may have guessed is the one thing the parser is not allowed to do, so it is not done here either — match those videos and the profiles arrive with them.",
                            icon: "person.crop.circle.badge.questionmark")
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
                if o.tags.attributeTagsOnVideos > 0 {
                    blocker("\(o.tags.attributeTagsOnVideos) performer traits sit on videos",
                            detail: "A video isn't a redhead — a performer is. These are left alone for enrichment to correct per performer, because which of the cast a trait describes is a guess.",
                            icon: "person.and.arrow.left.and.arrow.right")
                }
                if !o.tags.unknownTags.isEmpty {
                    blocker("\(o.tags.unknownTags.count) tags are not in the vocabulary",
                            detail: "Reported rather than created, so promoting and connecting stay separately checkable.",
                            icon: "questionmark.circle")
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
        } header: {
            Text("The graph now holds")
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        Section {
            // ⚠️ Checked per video, not by totals: a migration that connected
            // the right NUMBER of things to the wrong videos would pass a count.
            if disagreements.performers == 0 && disagreements.studios == 0 {
                Label("Every video's edges match its tags", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                Label("\(disagreements.performers + disagreements.studios) videos disagree with their tags",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Verification")
        } footer: {
            Text("Compared one video at a time. Matching totals would not prove the right things were connected to the right videos.")
        }
    }

    // MARK: - Pieces

    private func countRow(_ title: String, _ value: Int, of total: Int?) -> some View {
        LabeledContent(title) {
            if let total, total != value {
                Text("\(value) of \(total)").foregroundStyle(value == 0 ? .secondary : .primary)
            } else {
                Text("\(value)").foregroundStyle(value == 0 ? .secondary : .primary)
            }
        }
    }

    private func blocker(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.callout)
            Text(detail).font(.caption).foregroundStyle(.secondary)
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
            edgeCounts = try GraphEdgeKind.allCases.map { ($0, try store.edgeCount($0)) }
            disagreements = (try store.performerEdgeDisagreements().count,
                             try store.studioEdgeDisagreements().count)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}
