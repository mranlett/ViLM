// StudioImprintsView.swift
// Asking a network for its imprints, and showing what that would do before it
// does any of it.
//
// ⭐ Why this screen exists: reading a studio's `parent` alone discovers a
// network's imprints ONE MATCHED VIDEO AT A TIME — a real library accumulated
// 115 hierarchy rows that way. The source can answer the whole question in one
// request. `StudioHierarchy.plan` decides what to do with the answer and
// `applyStudioHierarchy` writes it; this is the part that lets a person look
// first.
//
// 🚨 PLAN, THEN APPLY. Filing imprints creates studios and re-points edges, and
// the two things the operator most needs to see — a refused loop and a parent
// they set by hand — are invisible in a result and obvious in a plan.
//
// ⚠️ ONE NETWORK AT A TIME (D1), never a library-wide sweep. Pulling every
// imprint of every network would create studios the library has no videos from,
// and a hierarchy is worth having because it explains the videos you hold.

import SwiftUI
import LibraryCore

struct StudioImprintsView: View {
    let libraryURL: URL
    /// The network being asked about.
    let profile: EntityProfile

    /// Whether anything was written, so the page behind can reload only when
    /// there is something new to show.
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var plan: StudioHierarchyPlan?
    @State private var aliases: StudioAliasPlan?
    /// What the source said about handing over fewer imprints than it has.
    @State private var sourceNote: String?
    @State private var arrivedCount = 0
    @State private var isWorking = true
    @State private var failure: String?
    @State private var outcome: LibraryStore.StudioHierarchyOutcome?

    private var provider: (any StudioMetadataProvider)? {
        PluginEnvironment.registry.installedStudioProviders().first
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(profile.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(outcome == nil ? "Cancel" : "Done") {
                            onFinish(outcome != nil)
                            dismiss()
                        }
                    }
                }
        }
        .macSheet(minWidth: 620, minHeight: 560)
        .task { await fetch() }
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            ProgressView(outcome == nil ? "Asking about its imprints…" : "Filing…")
        } else if let failure {
            ContentUnavailableView("Couldn't read its imprints",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if let outcome {
            result(outcome)
        } else if let plan {
            review(plan)
        }
    }

    // MARK: - The plan

    @ViewBuilder
    private func review(_ plan: StudioHierarchyPlan) -> some View {
        List {
            Section {
                LabeledContent("Imprints named", value: "\(arrivedCount)")
                // 🚨 Truncation is never hidden. A source that reports more
                // imprints than it hands over would otherwise present a partial
                // hierarchy as a complete one.
                if let sourceNote {
                    Text(sourceNote).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("What the source says")
            } footer: {
                if plan.isEmpty {
                    Text("Everything it named is already filed the way it says. Nothing to do.")
                }
            }

            if !plan.link.isEmpty {
                Section("File under \(profile.name)") {
                    ForEach(plan.link) { imprint in
                        imprintRow(imprint, note: "already in your library")
                    }
                }
            }

            if !plan.create.isEmpty {
                Section {
                    ForEach(plan.create) { imprint in
                        imprintRow(imprint, note: "you have no videos from this one")
                    }
                } header: {
                    Text("Add and file")
                } footer: {
                    // The operator's decision, restated where it takes effect:
                    // complete AND distinguishable.
                    Text("These complete the hierarchy. They are marked, so the studio list never implies you hold something you do not.")
                }
            }

            // 🔴 D4 — said either way. Silently keeping a hand-set parent looks
            // exactly like silently ignoring the source.
            if !plan.handSetKept.isEmpty {
                Section {
                    ForEach(plan.handSetKept) { ref in
                        Text(ref.name)
                    }
                } header: {
                    Text("Left as you set them")
                } footer: {
                    Text("The source files these elsewhere. You chose their network by hand, so nothing here changes it.")
                }
            }

            // 🚨 The chain is named. "Cycle" leaves the operator to find which
            // loop closed; the chain says it.
            if !plan.cycles.isEmpty {
                Section {
                    ForEach(plan.cycles, id: \.imprint.sourceId) { cycle in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cycle.imprint.name)
                            Text(cycle.chain.joined(separator: " → "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Refused — this would close a loop")
                } footer: {
                    Text("A studio cannot end up beneath itself. Nothing is written for these.")
                }
            }

            if !plan.unchanged.isEmpty {
                Section("Already filed") {
                    Text("\(plan.unchanged.count) imprint\(plan.unchanged.count == 1 ? "" : "s") "
                         + "already under \(profile.name).")
                        .foregroundStyle(.secondary)
                }
            }

            aliasSection

            if !plan.isEmpty {
                Section {
                    Button("File \(plan.link.count + plan.create.count) Imprint\(plan.link.count + plan.create.count == 1 ? "" : "s")") {
                        apply(plan)
                    }
                }
            }
        }
    }

    /// 🔴 D3/H5 — a candidate for review, never an automatic merge. Merging two
    /// studios re-points every video and every hierarchy row beneath them.
    @ViewBuilder
    private var aliasSection: some View {
        if let aliases, !aliases.candidates.isEmpty || !aliases.unmatched.isEmpty {
            if !aliases.candidates.isEmpty {
                Section {
                    ForEach(aliases.candidates, id: \.alias) { candidate in
                        Text(candidate.alias)
                    }
                } header: {
                    Text("Other spellings you hold separately")
                } footer: {
                    Text("Nothing is merged here. Fix Duplicate Studios is where a merge is decided.")
                }
            }
            if !aliases.unmatched.isEmpty {
                Section {
                    Text(aliases.unmatched.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Other spellings, none of which you hold")
                } footer: {
                    // H8 — an alias is a spelling, not an entity.
                    Text("Listed only. A spelling nothing in your library uses is not a studio, and no record is created for one.")
                }
            }
        }
    }

    private func imprintRow(_ imprint: PlannedImprint, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(imprint.ref.name)
            Text(imprint.ownsNoVideos ? "you have no videos from this one" : note)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - What happened

    private func result(_ outcome: LibraryStore.StudioHierarchyOutcome) -> some View {
        List {
            Section("Filed") {
                if !outcome.linked.isEmpty {
                    LabeledContent("Already held", value: "\(outcome.linked.count)")
                }
                if !outcome.created.isEmpty {
                    LabeledContent("Added", value: "\(outcome.created.count)")
                }
                if outcome.isEmpty {
                    Text("Nothing was written.").foregroundStyle(.secondary)
                }
            }
            // Reported by name, not thrown. The planner walked the hierarchy it
            // was handed; the database walks the one it has.
            if !outcome.refused.isEmpty {
                Section("Refused at the write") {
                    ForEach(outcome.refused, id: \.name) { refusal in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(refusal.name)
                            Text(refusal.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Doing it

    private func fetch() async {
        // ⚠️ A network the source cannot identify cannot be asked about. The
        // menu already gates on this; the screen refuses rather than trusting
        // it, because a request that can only fail reads as a broken feature.
        guard let sourceId = profile.enrichmentSourceId, !sourceId.isEmpty else {
            failure = "\(profile.name) has no source identity yet. Match it first, then its imprints can be looked up."
            isWorking = false
            return
        }
        guard let provider else {
            failure = "No studio source is installed."
            isWorking = false
            return
        }

        do {
            let proposal = try await provider.fetch(studioId: sourceId)
            let arriving = proposal.children.value ?? []
            let store = try LibraryStore(at: libraryURL)
            let local = try store.localStudios()

            arrivedCount = arriving.count
            sourceNote = proposal.children.sourceNote
            plan = StudioHierarchy.plan(network: profile.id, arriving: arriving,
                                        local: local,
                                        parentOf: { try? store.parentStudioId(of: $0) })
            aliases = StudioHierarchy.aliasPlan(proposal.akas.value ?? [],
                                                for: profile.id, local: local)
        } catch {
            failure = error.localizedDescription
        }
        isWorking = false
    }

    private func apply(_ plan: StudioHierarchyPlan) {
        isWorking = true
        do {
            let store = try LibraryStore(at: libraryURL)
            outcome = try store.applyStudioHierarchy(plan, under: profile.id,
                                                     source: provider?.displayName)
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"),
                                            object: nil)
        } catch {
            failure = error.localizedDescription
        }
        isWorking = false
    }
}
