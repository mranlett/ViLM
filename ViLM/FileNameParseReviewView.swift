// FileNameParseReviewView.swift
// Reads the library's filenames into the catalogue, after showing every change.
//
// A dry run by construction: the plan is computed, displayed and only then
// applied. D6 of the naming spec requires this of the rename that follows, and
// the same reasoning applies here — this writes to 2,000 records at once, and a
// wrong reading repeated two thousand times is far more expensive to undo than
// to inspect.
//
// Three groups, because they need different amounts of attention:
//
//   CLEAN       every segment of the name was recognised. Pre-ticked.
//   PARTIAL     something in the name could not be placed. Shown with the
//               leftover text, not ticked.
//   UNREADABLE  nothing was recognised. Not actionable, but listed — these are
//               the names worth teaching the vocabulary, and hiding them would
//               make the pass look more complete than it is.

import SwiftUI
import LibraryCore

struct FileNameParseReviewView: View {
    /// Every open library. Reading one at a time was wrong twice over: the
    /// other library goes untouched, AND the vocabulary is drawn from a smaller
    /// pool, so names that both libraries together could explain are reported
    /// as unreadable.
    let libraryURLs: [URL]
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var assets: [Asset] = []
    /// Which library owns each asset, so a write goes back where it came from.
    @State private var owner: [UUID: URL] = [:]
    @State private var libraryCount = 0
    @State private var proposals: [FileNameProposal] = []
    @State private var unreadable: [Asset] = []
    @State private var accepted: Set<UUID> = []
    @State private var isScanning = true
    @State private var isApplying = false
    @State private var summary: String?

    private var clean: [FileNameProposal] { proposals.filter(\.isClean) }
    private var partial: [FileNameProposal] { proposals.filter { !$0.isClean } }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Read Filenames")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onFinish(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !proposals.isEmpty {
                            Button(isApplying ? "Applying…" : "Apply \(accepted.count)") {
                                Task { await apply() }
                            }
                            .disabled(accepted.isEmpty || isApplying)
                        }
                    }
                }
        }
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if isScanning || isApplying {
            VStack(spacing: 10) {
                ProgressView()
                Text(isApplying ? "Writing…" : "Reading filenames…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let summary {
            ContentUnavailableView {
                Label("Done", systemImage: "checkmark.circle")
            } description: {
                Text(summary)
            } actions: {
                // A second pass reads more: every record just corrected has
                // widened the vocabulary the next parse works from.
                Button("Read again") { Task { await scan() } }
            }
        } else if proposals.isEmpty && unreadable.isEmpty {
            ContentUnavailableView("Nothing to read", systemImage: "checkmark.circle",
                                   description: Text("Every filename across \(libraryCount) open librar\(libraryCount == 1 ? "y" : "ies") is already reflected in the catalogue."))
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                summaryRow
            } footer: {
                Text("Nothing is written until you apply. Only missing fields are added — nothing already recorded is changed or removed.")
            }

            if !clean.isEmpty {
                Section {
                    ForEach(clean) { row($0) }
                } header: {
                    HStack {
                        Text("Fully read — \(clean.count)")
                        Spacer()
                        Button(accepted.isSuperset(of: clean.map(\.id)) ? "None" : "All") {
                            toggleAll(clean)
                        }
                        .font(.caption)
                    }
                } footer: {
                    Text("Every part of these names was recognised.")
                }
            }

            if !partial.isEmpty {
                Section {
                    ForEach(partial) { row($0) }
                } header: {
                    HStack {
                        Text("Partly read — \(partial.count)")
                        Spacer()
                        Button(accepted.isSuperset(of: partial.map(\.id)) ? "None" : "All") {
                            toggleAll(partial)
                        }
                        .font(.caption)
                    }
                } footer: {
                    // Worth stating plainly, because "partly read" sounds
                    // riskier than it is. Everything OFFERED here was matched
                    // against the library's own vocabulary, exactly as in the
                    // clean group — the orange text is simply the part of the
                    // name that went unused. Nothing is guessed: the one rule
                    // that infers a value only fires when a single segment is
                    // unplaced, and such rows land in the clean group.
                    Text("These are safe to accept — everything offered was recognised, and the orange text is only the part of the name that went unused. They are not pre-ticked because the leftover is worth a glance.")
                }
            }

            if !unreadable.isEmpty {
                Section {
                    ForEach(unreadable.prefix(50), id: \.id) { asset in
                        Text(asset.fileName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if unreadable.count > 50 {
                        Text("… and \(unreadable.count - 50) more")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Not recognised — \(unreadable.count)")
                } footer: {
                    Text("Nothing in these names matched anything the library knows. Tag a few by hand and read again — each one teaches the vocabulary.")
                }
            }
        }
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(proposals.count) of \(assets.count) filenames would add something")
                .font(.subheadline).fontWeight(.medium)
            if libraryCount > 1 {
                Text("Across \(libraryCount) open libraries — each change is written back to the library that holds it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(countsText).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// What the pass would actually contribute, by kind — the number that says
    /// whether this is worth doing at all.
    private var countsText: String {
        var actors = 0, studios = 0, tags = 0
        for proposal in proposals where accepted.contains(proposal.id) {
            for addition in proposal.additions {
                if addition.hasPrefix("actor:") { actors += 1 }
                else if addition.hasPrefix("studio:") { studios += 1 }
                else if addition.hasPrefix("tag:") { tags += 1 }
            }
        }
        return "\(actors) actors · \(studios) studios · \(tags) tags, from \(accepted.count) selected"
    }

    private func row(_ proposal: FileNameProposal) -> some View {
        Button {
            toggle(proposal.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: accepted.contains(proposal.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(accepted.contains(proposal.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.fileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    FlowLayout(spacing: 5) {
                        ForEach(proposal.additions, id: \.self) { addition in
                            chip(addition)
                        }
                        if let series = proposal.seriesBlock {
                            pill(series, color: .orange, icon: "tv")
                        }
                    }
                    // The text nothing could be made of. Shown because a reading
                    // that quietly drops half a name is worse than one that says
                    // which half it dropped.
                    if !proposal.parsed.unrecognised.isEmpty {
                        Text("couldn't place: \(proposal.parsed.unrecognised.joined(separator: " · "))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func chip(_ addition: String) -> some View {
        if addition.hasPrefix("actor:") {
            pill(String(addition.dropFirst(6)), color: .blue, icon: "person")
        } else if addition.hasPrefix("studio:") {
            pill(String(addition.dropFirst(7)), color: .purple, icon: "building.2")
        } else {
            pill(String(addition.dropFirst(4)), color: .green, icon: "tag")
        }
    }

    private func pill(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.18))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private func toggle(_ id: UUID) {
        if accepted.contains(id) { accepted.remove(id) } else { accepted.insert(id) }
    }

    private func toggleAll(_ group: [FileNameProposal]) {
        let ids = Set(group.map(\.id))
        if accepted.isSuperset(of: ids) { accepted.subtract(ids) } else { accepted.formUnion(ids) }
    }

    // MARK: - Work

    private func scan() async {
        isScanning = true
        summary = nil
        do {
            var all: [Asset] = []
            var ownership: [UUID: URL] = [:]
            var profiles: [String: EntityProfile] = [:]
            for url in libraryURLs {
                let store = try LibraryStore(at: url)
                let loaded = try store.fetchAllAssets()
                for asset in loaded { ownership[asset.id] = url }
                all += loaded
                // Profiles are pooled for the same reason assets are, and they
                // are what says which names have actually been CONFIRMED.
                // Without them every name carries equal authority, so a token
                // that is a known studio and a guessed actor resolves by check
                // order rather than by confidence.
                for profile in try store.fetchAllEntityProfiles() {
                    // A name confirmed ANYWHERE is confirmed — so a matched
                    // profile always wins, whichever library it came from.
                    // First-wins would let an unmatched copy in one library
                    // shadow a matched one in another and silently drop the
                    // confirmation.
                    if profile.enrichmentState == .matched || profiles[profile.id] == nil {
                        profiles[profile.id] = profile
                    }
                }
            }
            // Pooled across every open library. A studio known only to one of
            // them still explains a filename in the other, so pooling reads
            // MORE than scanning each alone would.
            let vocabulary = NameVocabulary(assets: all, profiles: profiles)
            assets = all
            owner = ownership
            libraryCount = libraryURLs.count
            proposals = FileNameParser.plan(assets: all, vocabulary: vocabulary)
            unreadable = FileNameParser.unreadable(assets: all, vocabulary: vocabulary)
            // Clean readings are pre-ticked; anything with leftover text is a
            // judgement and is not.
            accepted = Set(proposals.filter(\.isClean).map(\.id))
        } catch {
            AppErrorReporter.report("Couldn't read filenames: \(error.localizedDescription)")
        }
        isScanning = false
    }

    private func apply() async {
        isApplying = true
        var written = 0
        do {
            let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            // One store per library rather than per write: opening the same
            // database two thousand times is the difference between seconds and
            // minutes.
            var stores: [URL: LibraryStore] = [:]
            for proposal in proposals where accepted.contains(proposal.id) {
                guard let asset = byId[proposal.assetId],
                      let url = owner[proposal.assetId] else { continue }
                let store = try stores[url] ?? {
                    let opened = try LibraryStore(at: url)
                    stores[url] = opened
                    return opened
                }()
                try store.updateAsset(FileNameParser.applying(proposal, to: asset))
                written += 1
            }
            summary = "Updated \(written) video\(written == 1 ? "" : "s") from their filenames."
            proposals = []
            unreadable = []
            accepted = []
            NotificationCenter.default.post(name: NSNotification.Name("ReloadAssets"), object: nil)
        } catch {
            AppErrorReporter.report("Couldn't write: \(error.localizedDescription)")
        }
        isApplying = false
    }
}
