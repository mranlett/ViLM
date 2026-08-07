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
    /// Index of the chosen candidate's image being viewed full screen, on the
    /// review screen itself.
    @State private var expandedReview: Int?

    /// The record to open straight onto, skipping identification.
    ///
    /// ⚠️ Set ONLY when the operator arrived from a list that already names the
    /// disagreement — a refresh report's queue. From a video's own page the
    /// "already matched" screen is the point: it says the video is settled and
    /// makes re-matching a deliberate act.
    private let resumeMatchId: String?

    init(asset: Asset, libraryURL: URL, knownTags: Set<String>,
         resumeMatchId: String? = nil,
         onApply: @escaping (Asset) -> Void) {
        self.asset = asset
        self.libraryURL = libraryURL
        self.knownTags = knownTags
        self.resumeMatchId = resumeMatchId
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
                            if let outcome = model.outcomeToRecord() {
                                onApply(VideoEnrichmentReview.recordingOutcome(
                                    asset, state: outcome.state, source: outcome.source,
                                    sourceId: outcome.sourceId))
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
        // 🚨 On the CONTAINER, not on one phase's view.
        //
        // These lived on the picker. `picker` and `review` are separate
        // branches of a switch, so on the review screen the buttons set the
        // state and nothing was in the hierarchy to present it — tapping the
        // matched still, and "Tap to see all N images", both did nothing at
        // all. Reported from the device; the code reads as though it works,
        // which is why it survived.
        .sheet(item: $examining) { candidate in
            CandidateImageSheet(candidate: candidate) {
                examining = nil
                Task { await model.choose(candidate) }
            }
        }
        .sheet(item: Binding(
            get: { expandedReview.map(ExpandedImage.init) },
            set: { expandedReview = $0?.index }
        )) { item in
            if let candidate = model.chosenCandidate {
                RemotePhotoBrowser(urls: reviewImageURLs(candidate),
                                   title: candidate.title,
                                   initialIndex: item.index)
            }
        }
        .task {
            if let resumeMatchId {
                await model.resume(sourceId: resumeMatchId)
            } else {
                await model.start()
            }
        }
        // ⚠️ Its OWN sizing. The `.macSheet` further down this file belongs to
        // `CandidateImageSheet`, and the consistency gate searched the whole
        // FILE for one — so it saw that string and passed this struct, which
        // has never had any. On macOS the review is a `List`, which has no
        // intrinsic height, so the sheet rendered as a title bar and two
        // buttons with no content area at all.
        //
        // Most visible when opened FROM another sheet — a conflict queued by
        // Refresh Matched Videos — where there is no parent geometry to borrow.
        .macSheet(minWidth: 720, minHeight: 620)
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
    }

    /// Every image the chosen candidate has, falling back to the thumbnail.
    ///
    /// ⚠️ A candidate can carry a `thumbnailURL` and an empty `imageURLs` —
    /// the search response supplies the first and the full set only sometimes.
    /// Passing the empty array would open a browser onto nothing, which is
    /// worse than not offering the tap at all.
    private func reviewImageURLs(_ candidate: PluginCandidate) -> [URL] {
        candidate.imageURLs.isEmpty
            ? [candidate.thumbnailURL, candidate.fullImageURL].compactMap { $0 }
            : candidate.imageURLs
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

    // MARK: - Which studio

    /// Shown only when verification could not settle it — both names confirmed,
    /// or neither.
    ///
    /// ⚠️ Neither is pre-selected and no studio row appears until one is
    /// picked. A default here would be a studio nobody compared, applied by the
    /// same keystroke that accepts everything else.
    private func studioChoiceSection(
        _ choice: (imprint: StudioResolution.Candidate, parent: StudioResolution.Candidate)
    ) -> some View {
        Section {
            studioOption(choice.imprint, caption: "The label that released it")
            studioOption(choice.parent, caption: "The network that owns the label")
        } header: {
            Text("Which studio?")
        } footer: {
            Text(choice.imprint.isVerified && choice.parent.isVerified
                 ? "Both are studios you have already confirmed, so the source cannot say which this video should carry."
                 : "Neither has been confirmed yet. Whichever you pick is confirmed by picking it.")
        }
    }

    private func studioOption(_ candidate: StudioResolution.Candidate,
                              caption: String) -> some View {
        Button {
            model.chooseStudio(candidate)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name).font(.body)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if candidate.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Already confirmed")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Review

    private var review: some View {
        List {
            Section {
                VideoContextPanel(asset: asset, libraryURL: libraryURL)
            }

            if let candidate = model.chosenCandidate {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        // ⚠️ The still is its own button, opening full screen
                        // with pinch-to-zoom. It used to share one button with
                        // the text, which sent every tap to the image GRID —
                        // so on the review screen, the one place a single still
                        // is shown beside the data being accepted, the picture
                        // was the only thing that could not be enlarged.
                        Button { expandedReview = 0 } label: {
                            thumbnail(candidate)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption2)
                                        .padding(4)
                                        .background(.ultraThinMaterial, in: Circle())
                                        .padding(3)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Expand preview image")

                        Button { examining = candidate } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.title).font(.subheadline).fontWeight(.medium)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let subtitle = candidate.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if candidate.imageURLs.count > 1 {
                                    Text("Tap to see all \(candidate.imageURLs.count) images")
                                        .font(.caption2).foregroundStyle(.tint)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(candidate.imageURLs.count <= 1)
                    }
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

            if let choice = model.studioChoice {
                studioChoiceSection(choice)
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
                        // 🚨 Says WHY a familiar-looking tag is not ticked.
                        // These describe a performer, and the source puts them
                        // on its scenes — so "Redhead" arrived looking exactly
                        // like a tag about the video, and being classified was
                        // what made it tick by default.
                        if option.describesPerformer {
                            Text("describes a performer")
                                .font(.caption2).foregroundStyle(.orange)
                        } else if option.isKnown {
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
            Text("Tags already on this video are ticked — unticking one removes it. Tags you already use elsewhere are ticked too; the rest are offered but left off, so one match can't flood your tag list. Tags your vocabulary says describe a performer are never ticked automatically: a video isn't a redhead, a performer is.")
        }
    }
}

/// Which image is open full screen.
///
/// `sheet(item:)` needs an `Identifiable`, and a bare `Int` is not one — the
/// index is the identity here, so it is wrapped rather than stored twice.
private struct ExpandedImage: Identifiable {
    let index: Int
    var id: Int { index }
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
    /// Index of the image being viewed full screen, if any.
    @State private var expanded: Int?
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
                    ForEach(Array(candidate.imageURLs.enumerated()), id: \.element) { index, url in
                        // Tapping opens the full-screen zoomable browser at
                        // this image. Deciding whether two videos are the same
                        // work often comes down to a detail — a logo, a room, a
                        // face in the background — and a 240pt grid cell cannot
                        // settle that however many of them are on screen.
                        Button { expanded = index } label: {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 150)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .bottomTrailing) {
                                // Says the images are interactive. Without it
                                // nothing distinguishes this grid from a static
                                // contact sheet.
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2)
                                    .padding(5)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .padding(6)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Image \(index + 1) of \(candidate.imageURLs.count). Opens full screen.")
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
        // Sized to fit three of the grid's 240pt columns: this screen exists so
        // the images can be compared, and one column at a time is not a
        // comparison.
        .macSheet(minWidth: 820, minHeight: 640)
        .sheet(item: Binding(
            get: { expanded.map(ExpandedImage.init) },
            set: { expanded = $0?.index }
        )) { item in
            RemotePhotoBrowser(urls: candidate.imageURLs,
                               title: candidate.title,
                               initialIndex: item.index)
        }
    }
}
