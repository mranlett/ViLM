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
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if case .reviewing = model.phase {
                            Button("Apply") {
                                if let updated = model.apply() { onApply(updated) }
                                dismiss()
                            }
                            .disabled(!model.hasAnythingToApply)
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

    private func picker(_ candidates: [PluginCandidate]) -> some View {
        List(candidates) { candidate in
            Button {
                Task { await model.choose(candidate) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail(candidate)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.title).font(.subheadline).fontWeight(.medium)
                        if let subtitle = candidate.subtitle {
                            // Date, studio and cast — the three things that
                            // separate two scenes with near-identical names.
                            Text(subtitle).font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("\(candidates.count) possible matches")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("None of these") { model.beginBrowsing() }.font(.caption)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func thumbnail(_ candidate: PluginCandidate) -> some View {
        if let url = candidate.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 96, height: 54)
                .overlay(Image(systemName: "film").foregroundColor(.secondary))
        }
    }

    // MARK: - Review

    private var review: some View {
        List {
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
            Text("Tags you already use are ticked. The rest are offered but left off, so one match can't flood your tag list.")
        }
    }
}
