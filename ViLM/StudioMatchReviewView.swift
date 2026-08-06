// StudioMatchReviewView.swift
// Choosing between the studios a source offered for one name.
//
// ⚠️ This exists because the batch queue was unusable without it. A queued
// studio opened the profile EDITOR, which shows the record you already have and
// never the candidates that caused it to be queued — so the one question the
// queue asks ("which of these is it?") could not be seen, let alone answered.
//
// The candidates are handed in rather than re-searched. The batch run already
// paid for that request, and searching again would spend a second one to get
// the same answer — and could get a different one, which is worse.
//
// Deliberately smaller than `ActorEnrichmentSheet`. Telling two performers
// apart needs photographs at size, which is most of that screen; telling two
// studios apart needs the network that owns each, which is one line.

import SwiftUI
import LibraryCore

struct StudioMatchReviewView: View {
    let libraryURL: URL
    let profile: EntityProfile
    let candidates: [PluginCandidate]
    /// The network already recorded, if any — so a disagreement is visible
    /// before it is accepted rather than after.
    let existingParent: String?

    /// What the operator did here.
    ///
    /// ⚠️ Reported back rather than just dismissing. The first version only
    /// closed the sheet, so a studio the operator had just matched stayed in
    /// the run's "need you to choose" list — settled everywhere except the one
    /// screen that had asked the question.
    enum Outcome {
        /// Saved against a candidate.
        case matched
        /// "None of these" — recorded `unmatchable`.
        case ruledOut
        /// Closed without deciding. The record is still queued.
        case dismissed
    }

    var onFinish: (Outcome) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var chosen: PluginCandidate?
    @State private var proposal: StudioMetadataProposal?
    @State private var accepted: Set<String> = []
    @State private var isFetching = false
    @State private var failure: String?

    private var studioName: String {
        profile.id.hasPrefix("studio:") ? String(profile.id.dropFirst(7)) : profile.id
    }

    private var provider: (any StudioMetadataProvider)? {
        PluginEnvironment.registry.installedStudioProviders().first
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(studioName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Closing without deciding leaves it queued, which is
                        // true — nothing was written.
                        Button("Close") { onFinish(.dismissed); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if proposal != nil {
                            Button("Save") { apply() }
                        }
                    }
                }
        }
        .macSheet(minWidth: 640, minHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        if isFetching {
            ProgressView("Fetching…")
        } else if let failure {
            ContentUnavailableView("Couldn't fetch that studio",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if proposal != nil {
            confirmation
        } else {
            picker
        }
    }

    // MARK: - Choosing

    private var picker: some View {
        List {
            Section {
                LabeledContent("In your library", value: studioName)
                LabeledContent("Videos", value: "\(videoCount)")
                if let existingParent {
                    LabeledContent("Network on record", value: existingParent)
                }
            } header: {
                Text("What you have")
            } footer: {
                Text("The source returned \(candidates.count) studios for this name. Two networks can use the same imprint name, which is why this was queued rather than matched.")
            }

            Section("Which of these is it?") {
                ForEach(candidates) { candidate in
                    Button { choose(candidate) } label: {
                        HStack(spacing: 12) {
                            logo(for: candidate)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).font(.body)
                                // ⚠️ The distinguishing fact. Without it these
                                // rows are identical text and the choice is a
                                // coin flip.
                                Text(candidate.subtitle.map { "Part of \($0)" }
                                     ?? "No network recorded")
                                    .font(.caption)
                                    .foregroundStyle(candidate.subtitle == nil
                                                     ? .secondary : .primary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button(role: .destructive) { ruleOut() } label: {
                    Label("None of these", systemImage: "xmark.circle")
                }
            } footer: {
                Text("Marks the studio as not findable, so future runs skip it. You can undo that by editing the profile.")
            }
        }
    }

    @ViewBuilder
    private func logo(for candidate: PluginCandidate) -> some View {
        if let url = candidate.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView()
            }
            .frame(width: 56, height: 40)
        } else {
            Image(systemName: "building.2")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 40)
        }
    }

    // MARK: - Confirming

    private var confirmation: some View {
        List {
            if let chosen {
                Section("Matched to") {
                    HStack(spacing: 12) {
                        logo(for: chosen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chosen.title).font(.body)
                            Text(chosen.subtitle ?? "No network recorded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                ForEach(offers, id: \.field) { offer in
                    Toggle(isOn: binding(for: offer.field)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(offer.label).font(.callout)
                            Text(offer.proposed).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let current = offer.current {
                                // ⚠️ Named as a replacement, not a fill. A
                                // conflict defaults OFF, and the operator has
                                // to see what they are discarding to overrule
                                // that meaningfully.
                                Text("replaces: \(current)")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("What to save")
            } footer: {
                Text(offers.isEmpty
                     ? "The source had nothing this record does not already hold. Saving still records the match, so this studio is confirmed and future runs skip it."
                     : "Empty fields are ticked. Anything that would replace a value you already have is left unticked.")
            }

            // ⚠️ Never offered. The name is the join key every video's
            // `studio:` tag is filed under, so changing it is a library-wide
            // rename — Repair Tag Spelling does that, with the whole library in
            // view.
            if let proposed = proposal?.name.value,
               proposed.caseInsensitiveCompare(studioName) != .orderedSame {
                Section {
                    Label("The source spells this “\(proposed)”.",
                          systemImage: "character.cursor.ibeam")
                        .font(.caption)
                } footer: {
                    Text("Not changed here. Renaming a studio moves every video filed under it, so it belongs in Repair Tag Spelling.")
                }
            }
        }
    }

    /// One offerable value, with whatever it would displace.
    private struct Offer {
        let field: String
        let label: String
        let proposed: String
        /// `nil` when the slot is empty — that is a fill, and it defaults on.
        let current: String?
    }

    private var offers: [Offer] {
        guard let proposal else { return [] }
        var result: [Offer] = []

        if let parent = proposal.parentName.value, !parent.isEmpty {
            let conflicting = existingParent.flatMap {
                StudioResolution.isSameStudio($0, parent) ? nil : $0
            }
            result.append(Offer(field: StudioBatchPolicy.Field.parent,
                                label: "Network", proposed: parent,
                                current: conflicting))
        }
        if let bio = proposal.bio.value, !bio.isEmpty {
            result.append(Offer(field: StudioBatchPolicy.Field.bio,
                                label: "Notes", proposed: bio, current: profile.bio))
        }
        if let home = proposal.homePage.value, !home.isEmpty {
            result.append(Offer(field: StudioBatchPolicy.Field.homePage,
                                label: "Home page", proposed: home,
                                current: profile.homePage))
        }
        if let akas = proposal.akas.value, !akas.isEmpty {
            result.append(Offer(field: StudioBatchPolicy.Field.akas,
                                label: "Also known as",
                                proposed: akas.joined(separator: ", "),
                                current: profile.akas.isEmpty
                                    ? nil : profile.akas.joined(separator: ", ")))
        }
        if let links = proposal.externalLinks.value, !links.isEmpty {
            result.append(Offer(field: StudioBatchPolicy.Field.links,
                                label: "Links",
                                proposed: links.map(\.url).joined(separator: ", "),
                                current: profile.links.isEmpty
                                    ? nil : "\(profile.links.count) already saved"))
        }
        if let logo = proposal.logoURL.value {
            result.append(Offer(field: StudioBatchPolicy.Field.logoUrl,
                                label: "Logo", proposed: logo.absoluteString,
                                current: profile.photoUrl))
        }
        return result
    }

    private func binding(for field: String) -> Binding<Bool> {
        Binding(get: { accepted.contains(field) },
                set: { isOn in
                    if isOn { accepted.insert(field) } else { accepted.remove(field) }
                })
    }

    // MARK: - Actions

    private var videoCount: Int {
        (try? LibraryStore(at: libraryURL).videoIds(forStudio: profile.id).count) ?? 0
    }

    private func choose(_ candidate: PluginCandidate) {
        guard let provider else { return }
        chosen = candidate
        isFetching = true
        failure = nil
        Task {
            do {
                let fetched = try await provider.fetch(studioId: candidate.id)
                proposal = fetched
                // Fills tick themselves; anything that would replace an
                // existing value starts off, so a careless Save cannot discard
                // work the operator did.
                accepted = Set(offers.filter { $0.current == nil }.map(\.field))
            } catch {
                failure = (error as? PluginError)?.localizedDescription
                    ?? error.localizedDescription
            }
            isFetching = false
        }
    }

    private func apply() {
        guard let proposal, let chosen else { return }
        guard let store = try? LibraryStore(at: libraryURL) else { return }

        var updated = profile
        if accepted.contains(StudioBatchPolicy.Field.bio) { updated.bio = proposal.bio.value }
        if accepted.contains(StudioBatchPolicy.Field.homePage) {
            updated.homePage = proposal.homePage.value
        }
        if accepted.contains(StudioBatchPolicy.Field.akas) {
            updated.akas = proposal.akas.value ?? []
        }
        if accepted.contains(StudioBatchPolicy.Field.links) {
            updated.links = proposal.externalLinks.value ?? []
        }
        if accepted.contains(StudioBatchPolicy.Field.logoUrl) {
            updated.photoUrl = proposal.logoURL.value?.absoluteString
        }

        updated.enrichmentState = .matched
        updated.enrichmentSource = provider?.displayName
        updated.enrichmentSourceId = proposal.sourceId.value ?? chosen.id
        updated.enrichmentCheckedAt = Date()
        try? store.saveEntityProfile(updated)

        // The network is written last and only if ticked: the imprint's own row
        // has to exist first, and an edge to a studio with no profile is a
        // dangling parent — one of the defects Studio Health reports.
        if accepted.contains(StudioBatchPolicy.Field.parent),
           let parent = proposal.parentName.value, !parent.isEmpty {
            try? store.confirmStudio(parent, source: provider?.displayName)
            try? store.setStudioParent("studio:\(parent)", forStudio: updated.id)
        }

        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        onFinish(.matched)
        dismiss()
    }

    /// Ruled out by a person, which is a different state from "the source had
    /// nothing" — `unmatchable` is skipped on every future run.
    private func ruleOut() {
        guard let store = try? LibraryStore(at: libraryURL) else { return }
        var updated = profile
        updated.enrichmentState = .unmatchable
        updated.enrichmentCheckedAt = Date()
        try? store.saveEntityProfile(updated)
        NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        onFinish(.ruledOut)
        dismiss()
    }
}
