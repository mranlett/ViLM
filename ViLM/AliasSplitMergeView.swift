// AliasSplitMergeView.swift
// Settings tool: one performer recorded as two profiles, reunited.
//
// 🚨 The cleanup for the credited-name inversion. The video plugin preferred
// the name a performer was CREDITED under in a scene over their canonical name,
// so someone who worked under three aliases became three profiles — each with
// part of a filmography, none with all of it.
//
// ⭐ The evidence is already in the data: the surviving profile lists the other
// one's name in its own aliases. This screen assembles that and hands it over.
//
// ⚠️ It never merges on its own, and there is deliberately no "merge all".
// A short alias can belong to more than one performer — the real library has
// one name listed as an alias of two different people — and a wrong merge
// fuses two careers into one profile, which no later tool can separate.

import SwiftUI
import LibraryCore

struct AliasSplitMergeView: View {
    @Environment(\.dismiss) private var dismiss

    let libraryURL: URL
    let onRefresh: () -> Void

    @State private var candidates: [AliasSplitCandidate] = []
    @State private var isLoading = true
    @State private var isMerging = false
    @State private var merged = 0
    @State private var errorMessage: String?
    /// The merge awaiting confirmation: which profile goes, which survives.
    /// 🚨 NAMES, not ids. The merge is performed by `renameTagGlobally`, which
    /// matches `actor:Name` strings in `Asset.tags` — so handing it profile
    /// ids silently matched nothing. Before the re-key an id WAS `actor:Name`
    /// and this worked; afterwards it became a uid and the merge quietly
    /// stopped doing anything, while the dialog showed the uid to the operator.
    @State private var pending: (losing: String, surviving: String)?
    /// Candidates the operator has explicitly set aside this session.
    @State private var dismissed: Set<String> = []

    private var visible: [AliasSplitCandidate] {
        candidates.filter { !dismissed.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Duplicate Performers")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            if merged > 0 { onRefresh() }
                            dismiss()
                        }
                    }
                }
                .overlay {
                    if isMerging {
                        ProgressView("Merging…")
                            .padding().background(.regularMaterial).cornerRadius(10)
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: { Text(errorMessage ?? "") }
                .confirmationDialog(
                    pending.map { "Merge \($0.losing) into \($0.surviving)?" } ?? "",
                    isPresented: Binding(get: { pending != nil },
                                         set: { if !$0 { pending = nil } }),
                    titleVisibility: .visible
                ) {
                    if let pending {
                        Button("Merge", role: .destructive) {
                            Task { await merge(losing: pending.losing, surviving: pending.surviving) }
                        }
                    }
                    Button("Cancel", role: .cancel) { pending = nil }
                } message: {
                    Text("Every video, photo and alias moves across. This cannot be undone, and two performers merged by mistake cannot be separated again.")
                }
                .task { await load() }
        }
        .macFormSheet(minWidth: 620, minHeight: 540)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Looking for duplicates…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40)).foregroundStyle(.green)
                Text(merged > 0
                     ? "\(merged) performer\(merged == 1 ? "" : "s") merged."
                     : "No duplicate performers found.")
                    .font(.title3)
                Text("This looks for a profile whose name is recorded as an alias of a different profile — which is how one performer ends up filed as two.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section {
                    Text(headline).font(.callout)
                } footer: {
                    Text("Each of these is one profile whose name another profile lists as an alias. Merging keeps the name you choose; every video, photo and alias moves across.")
                }

                ForEach(visible) { candidate in
                    section(for: candidate)
                }
            }
        }
    }

    private var headline: String {
        let ambiguous = visible.filter(\.isAmbiguous).count
        let clear = visible.count - ambiguous
        if ambiguous == 0 {
            return "\(clear) likely duplicate\(clear == 1 ? "" : "s")."
        }
        if clear == 0 {
            return "\(ambiguous) name\(ambiguous == 1 ? "" : "s") claimed by more than one performer — each needs your judgement."
        }
        return "\(clear) likely duplicate\(clear == 1 ? "" : "s"), and \(ambiguous) claimed by more than one performer — those need your judgement."
    }

    @ViewBuilder
    private func section(for candidate: AliasSplitCandidate) -> some View {
        Section {
            row(candidate.alias, note: "listed as an alias elsewhere")

            ForEach(candidate.claimants) { claimant in
                row(claimant, note: "lists “\(candidate.alias.displayName)” as an alias")

                HStack {
                    Button("Keep \(claimant.displayName)") {
                        pending = (losing: candidate.alias.displayName,
                                   surviving: claimant.displayName)
                    }
                    .disabled(isMerging)
                    Spacer()
                    // ⚠️ Offered both ways. The profile listing the alias is
                    // usually the fuller record, but not always — the operator
                    // may have enriched the other one by hand.
                    Button("Keep \(candidate.alias.displayName)") {
                        pending = (losing: claimant.displayName,
                                   surviving: candidate.alias.displayName)
                    }
                    .disabled(isMerging)
                }
                .font(.caption)
            }

            Button("Not the same person") { dismissed.insert(candidate.id) }
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Image(systemName: candidate.isAmbiguous
                      ? "questionmark.circle" : "person.2")
                    .foregroundStyle(candidate.isAmbiguous ? .orange : .secondary)
                Text(candidate.alias.displayName)
                // ⭐ D2 is a RANKING, and a ranking nobody can see buys nothing.
                // The list is already ordered by evidence; this says why, so the
                // operator knows which rows are a fact and which are a guess.
                if candidate.evidence != .aliasOverlap {
                    Label(candidate.evidence == .both ? "confirmed" : "source merge",
                          systemImage: "arrow.triangle.merge")
                        .font(.caption2).labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                }
                Spacer()
                Text("\(candidate.combinedVideos) video\(candidate.combinedVideos == 1 ? "" : "s")")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } footer: {
            if candidate.isAmbiguous {
                // 🚨 The one case where being helpful would be harmful.
                Text("⚠️ \(candidate.claimants.count) performers list this name as an alias, so it cannot be a duplicate of all of them. Check the photos and dates before choosing — or leave it.")
            } else if candidate.upstreamSurvivorId != nil {
                // ⚠️ Says what the source did and what it did NOT do. An
                // upstream merge means the source decided two of ITS records
                // were one person; it does not decide that for these two local
                // profiles, so the operator still confirms (D1).
                Text(candidate.evidence == .both
                     ? "The source has already merged these two records, and the names overlap. Still worth a glance before you confirm."
                     : "The source has already merged these two records — the names do not overlap, so nothing else would have found this. Still worth a glance before you confirm.")
            }
        }
    }

    @ViewBuilder
    private func row(_ claimant: AliasSplitCandidate.Claimant, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(claimant.displayName).fontWeight(.medium)
                if claimant.isMatched {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                Text("\(claimant.videoCount) video\(claimant.videoCount == 1 ? "" : "s")")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            // The two facts that most often settle it: whether a lookup has
            // confirmed the profile, and whether the birth years agree.
            Text([note, claimant.birthYear.map { "born \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            let url = libraryURL
            let found = try await Task.detached(priority: .userInitiated) {
                try LibraryStore(at: url).auditAliasSplits()
            }.value
            await MainActor.run {
                self.candidates = found
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Couldn't read the library: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    /// ⭐ The decision lives in `AliasMerge`, where it can be tested. Both
    /// halves of it shipped broken inside this view: it passed profile ids to
    /// a function that matches tag strings, and then discarded the result, so
    /// a rename that matched nothing counted as a merge.
    private func merge(losing: String, surviving: String) async {
        pending = nil
        isMerging = true
        let url = libraryURL
        let outcome = await Task.detached(priority: .userInitiated) {
            AliasMerge.perform(losing: losing, surviving: surviving, in: url)
        }.value

        if let message = outcome.message {
            errorMessage = message
        } else {
            merged += 1
            await load()
        }
        isMerging = false
    }
}
