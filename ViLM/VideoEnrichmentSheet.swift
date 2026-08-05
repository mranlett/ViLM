// VideoEnrichmentSheet.swift
// The review surface for matching one video against a metadata source.
//
// Structured so the safe path is short: a fingerprint match with only empty
// fields to fill needs one glance and one button. Everything that demands
// judgement — a candidate to choose between, a value that disagrees with one
// already recorded, a tag the library has never used — is visually separated
// and never pre-selected.

import SwiftUI
import LibraryCore

struct VideoEnrichmentSheet: View {
    let asset: Asset
    let libraryURL: URL
    /// Tags this library already uses, which decides what gets ticked.
    let knownTags: Set<String>
    var onApply: (Asset) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VideoEnrichmentModel
    @State private var examining: PluginCandidate?

    init(asset: Asset, libraryURL: URL, knownTags: Set<String>,
         onApply: @escaping (Asset) -> Void) {
        self.asset = asset
        self.libraryURL = libraryURL
        self.knownTags = knownTags
        self.onApply = onApply
        _model = StateObject(wrappedValue: VideoEnrichmentModel(
            asset: asset, libraryURL: libraryURL, knownTags: knownTags))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Match Video")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            // A search that found nothing still happened. Losing
                            // that on dismissal means the video is offered as
                            // unchecked forever.
                            if let (state, source) = model.outcomeToRecord() {
                                onApply(VideoEnrichmentReview.recordingOutcome(
                                    asset, state: state, source: source))
                            }
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if case .reviewing = model.phase {
                            // Never disabled: confirming a match with nothing
                            // left to add is still a decision, and it has to be
                            // recordable or the video returns to the queue.
                            Button(model.hasAnythingToApply ? "Apply" : "Confirm Match") {
                                if let updated = model.apply() { onApply(updated) }
                                dismiss()
                            }
                        }
                    }
                }
        }
        .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .fingerprinting:
            // Named honestly: this step reads the whole video off disk and is
            // the slow one. "Searching" would imply the network and make a
            // local delay look like a stall.
            progress("Fingerprinting the video…",
                     detail: "Sampling frames to identify it by sight.")
        case .searching:
            progress("Searching…", detail: nil)
        case .fetching:
            progress("Loading details…", detail: nil)
        case .choosing(let candidates):
            picker(candidates)
        case .browsing:
            VideoManualSearchView(model: model) { candidate in
                Task { await model.choose(candidate) }
            }
        case .reviewing:
            review
        case .alreadyResolved(let state, let source, let at):
            ContentUnavailableView {
                Label(state == .matched ? "Already matched" : "Ruled out",
                      systemImage: state == .matched ? "checkmark.seal" : "person.crop.circle.badge.xmark")
            } description: {
                Text(resolvedDetail(state: state, source: source, at: at))
            } actions: {
                Button("Match again") { Task { await model.start(force: true) } }
            }

        case .noMatches:
            // Not a dead end. The operator knows things the matcher does not —
            // that the cast list is short, that the studio is recorded as a
            // tag, that the release is under a different name.
            ContentUnavailableView {
                Label("No automatic match", systemImage: "questionmark.video")
            } description: {
                Text("The fingerprint isn't in the database. A re-cut or trimmed copy will never match one, even when the scene is there — its length no longer lines up.")
            } actions: {
                Button("Search by hand") { model.beginBrowsing() }
                    .buttonStyle(.borderedProminent)
            }
        case .nothingToApply:
            ContentUnavailableView(
                "Already up to date",
                systemImage: "checkmark.circle",
                description: Text("The source agrees with everything already recorded."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't match this video", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Search by hand") { model.beginBrowsing() }
            }
        }
    }

    /// States plainly what is recorded and when, so "did that save?" is
    /// answerable by looking rather than by re-running the match.
    private func resolvedDetail(state: EnrichmentState, source: String?, at: Date?) -> String {
        var parts: [String] = []
        parts.append(state == .matched
                     ? "This video was matched\(source.map { " to \($0)" } ?? "")."
                     : "You marked this one as not findable.")
        if let at {
            parts.append("Recorded \(at.formatted(date: .abbreviated, time: .shortened)).")
        }
        parts.append("Batch runs skip it.")
        return parts.joined(separator: " ")
    }

    private func progress(_ title: String, detail: String?) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    // MARK: - Choosing between candidates

    /// Choosing between candidates is a VISUAL act. The previous version of
    /// this showed two 96×54 stills with no way to enlarge them and no sight of
    /// the file being matched — so the only way to compare was to accept one,
    /// look, then cancel back out and start again.
    private func picker(_ candidates: [PluginCandidate]) -> some View {
        List {
            Section {
                // The file's own frames, right here. Comparing against
                // something you have to remember is not comparing.
                VideoContextPanel(asset: asset, libraryURL: libraryURL)
            }

            Section {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            } header: {
                HStack {
                    Text("\(candidates.count) possible matches")
                    Spacer()
                    Button("None of these") { model.beginBrowsing() }.font(.caption)
                }
            } footer: {
                Text("Tap a picture to see every image the source has for it, at a size worth looking at. Tap the text to choose.")
            }
        }
        .sheet(item: $examining) { candidate in
            CandidateImageSheet(candidate: candidate) {
                examining = nil
                Task { await model.choose(candidate) }
            }
        }
    }

    private func candidateRow(_ candidate: PluginCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { examining = candidate } label: {
                ZStack(alignment: .bottomTrailing) {
                    thumbnail(candidate)
                    if candidate.imageURLs.count > 1 {
                        Text("\(candidate.imageURLs.count)")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.6)).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(3)
                    }
                }
            }
            .buttonStyle(.plain)

            Button { Task { await model.choose(candidate) } } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).font(.subheadline).fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = candidate.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let seconds = candidate.durationSeconds {
                        Text(durationText(seconds)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func durationText(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, s)
                       : String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private func thumbnail(_ candidate: PluginCandidate) -> some View {
        if let url = candidate.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
            // Large enough to recognise a scene from, which 96×54 was not.
            .frame(width: 132, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 132, height: 74)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
        }
    }

    // MARK: - Review

    private var review: some View {
        List {
            Section {
                VideoContextPanel(asset: asset, libraryURL: libraryURL)
            }

            if let candidate = model.chosenCandidate {
                Section {
                    Button { examining = candidate } label: {
                        HStack(alignment: .top, spacing: 12) {
                            thumbnail(candidate)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.title).font(.subheadline).fontWeight(.medium)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let subtitle = candidate.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text("Tap to see all \(candidate.imageURLs.count) images")
                                    .font(.caption2).foregroundStyle(.tint)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Matched to")
                } footer: {
                    // Metadata alone frequently is not enough to be sure. The
                    // picture is what settles it, so it belongs on the screen
                    // where the decision is made rather than one level down.
                    Text("Check this is the same video before applying.")
                }
            }

            if let route = model.matchRoute {
                Section {
                    Label(route, systemImage: routeIcon)
                        .font(.caption)
                        .foregroundColor(model.matchRoute?.contains("fingerprint") == true ? .green : .orange)
                    if model.canReturnToPicker {
                        Button("Choose a different match") { model.returnToPicker() }
                            .font(.caption)
                    }
                    Button("Search by hand instead") { model.beginBrowsing() }
                        .font(.caption)
                }
            }

            let fills = model.changes.filter { $0.kind == .fill }
            let conflicts = model.changes.filter { $0.kind == .conflict }

            if !fills.isEmpty {
                Section {
                    ForEach(fills) { row(for: $0) }
                } header: {
                    Text("New information")
                } footer: {
                    Text("These fields are empty, so nothing is overwritten.")
                }
            }

            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts) { row(for: $0) }
                } header: {
                    Text("Disagreements")
                } footer: {
                    Text("The source disagrees with what's recorded. Nothing here is applied unless you tick it.")
                }
            }

            if !model.tagOptions.isEmpty { tagSection }
        }
    }

    private var routeIcon: String {
        model.matchRoute?.contains("fingerprint") == true ? "checkmark.seal" : "questionmark.circle"
    }

    private func row(for change: VideoFieldChange) -> some View {
        Button {
            model.toggle(change.field)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.accepted.contains(change.field)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(model.accepted.contains(change.field) ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.label).font(.subheadline).fontWeight(.medium)
                    if change.kind == .conflict {
                        Text("now: \(change.current)").font(.caption).foregroundColor(.secondary)
                    }
                    Text(change.proposed).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = change.sourceNote {
                        Text(note).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tagSection: some View {
        Section {
            ForEach(model.tagOptions) { option in
                Button {
                    model.toggleTag(option.name)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.acceptedTags.contains(option.name)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(model.acceptedTags.contains(option.name)
                                             ? .accentColor : .secondary)
                        Text(option.name)
                        Spacer()
                        // Marks the ones already in the library's vocabulary,
                        // which is also the rule that decided what was ticked.
                        if option.isKnown {
                            Text("in use").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Tags — \(model.acceptedTags.count) of \(model.tagOptions.count)")
                Spacer()
                Button("All") { model.selectAllTags() }.font(.caption)
                Button("None") { model.selectNoTags() }.font(.caption)
            }
        } footer: {
            Text("Tags already on this video are ticked — unticking one removes it. Tags you already use elsewhere are ticked too; the rest are offered but left off, so one match can't flood your tag list.")
        }
    }
}

/// Every image a candidate has, at a size worth looking at.
///
/// Separate from the row because the two answer different questions: a row asks
/// "is this worth a closer look", this asks "is this the one". Choosing from
/// here returns straight to the flow rather than making you back out and start
/// the picker again.
private struct CandidateImageSheet: View {
    let candidate: PluginCandidate
    var onChoose: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let subtitle = candidate.subtitle {
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(candidate.imageURLs, id: \.self) { url in
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 150)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding()
            }
            .navigationTitle(candidate.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // "Back", not "Cancel": this returns to the list of candidates,
                // which is where you were.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("This is it") { onChoose() }
                }
            }
        }
    }
}
