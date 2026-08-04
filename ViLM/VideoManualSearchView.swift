// VideoManualSearchView.swift
// Searching a metadata source by hand, when the automatic passes found nothing.
//
// "No match" is a poor place to stop. A person looking at their own file knows
// things the matcher does not — that the cast list is incomplete, that the
// studio segment of the filename is actually a tag, that the name on the box is
// different again. This gives them the same controls they would use on the
// website: who is in it, who released it, and what it might be called.
//
// The filters are seeded from the library's own record because that is what a
// person would type anyway, and then left entirely editable.
//
// Two things make a shortlist decidable, and both are here: RUNNING TIME, shown
// against the file's own so a near-identical length stands out, and IMAGES,
// which are how anyone actually recognises a scene. A row's thumbnail expands
// into the full set the source holds.

import SwiftUI
import LibraryCore

struct VideoManualSearchView: View {
    @ObservedObject var model: VideoEnrichmentModel
    var onChoose: (PluginCandidate) -> Void

    @State private var newPerformer = ""
    @State private var newTag = ""
    @State private var showsSubject = false
    @State private var expanded: PluginCandidate?

    var body: some View {
        VStack(spacing: 0) {
            subjectGrid
            filters
            Divider()
            results
        }
        .sheet(item: $expanded) { candidate in
            CandidateGallery(candidate: candidate) {
                expanded = nil
                onChoose(candidate)
            }
        }
    }

    /// The file's own frames, collapsed by default.
    ///
    /// Recognising a scene means comparing it against something, and asking
    /// someone to hold sixteen frames in their head while scrolling a list of
    /// candidates is asking them to guess. Collapsed to begin with because the
    /// filters are what you reach for first; one tap away when the results
    /// start looking similar.
    @ViewBuilder
    private var subjectGrid: some View {
        DisclosureGroup(isExpanded: $showsSubject) {
            DetailGridView(asset: model.subject,
                           libraryURL: model.subjectLibraryURL,
                           isInteractive: false)
                .padding(.bottom, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3")
                Text("This video").font(.caption).fontWeight(.medium)
                if let local = model.localDuration {
                    Text(timeText(local)).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal).padding(.top, 8)
    }

    // MARK: - Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cast").font(.caption).foregroundColor(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(model.searchPerformers, id: \.self) { name in
                        HStack(spacing: 4) {
                            Text(name)
                            Button {
                                model.removeSearchPerformer(name)
                            } label: {
                                Image(systemName: "xmark.circle.fill").opacity(0.6)
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.blue.opacity(0.18))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                    }
                }
                HStack {
                    TextField("Add a performer…", text: $newPerformer)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                        .onSubmit { commitPerformer() }
                        .onChange(of: newPerformer) { _, text in
                            model.updateSuggestions(for: .performer, text: text)
                        }
                    Button("Add") { commitPerformer() }
                        .disabled(newPerformer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                completions(.performer) { name in
                    model.addSearchPerformer(name)
                    newPerformer = ""
                }
            }

            HStack(spacing: 8) {
                TextField("Studio", text: $model.searchStudio)
                    .autocorrectionDisabled()
                    .onChange(of: model.searchStudio) { _, text in
                        model.updateSuggestions(for: .studio, text: text)
                    }
                TextField("Title contains…", text: $model.searchTitle)
                    .autocorrectionDisabled()
            }
            completions(.studio) { name in model.searchStudio = name }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").font(.caption).foregroundColor(.secondary)
                if !model.searchTags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(model.searchTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                Button { model.removeSearchTag(tag) } label: {
                                    Image(systemName: "xmark.circle.fill").opacity(0.6)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.green.opacity(0.18))
                            .foregroundColor(.green)
                            .clipShape(Capsule())
                        }
                    }
                }
                // The video's own tags, one tap away. Not applied by default:
                // tags narrow hard, and several at once would open on an empty
                // list for a search nobody asked for.
                if !model.suggestedSearchTags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(model.suggestedSearchTags.prefix(8), id: \.self) { tag in
                            Button { model.addSearchTag(tag) } label: {
                                Label(tag, systemImage: "plus").font(.caption2)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                    }
                }
                HStack {
                    TextField("Add a tag…", text: $newTag)
                        .autocorrectionDisabled()
                        .onSubmit { commitTag() }
                        .onChange(of: newTag) { _, text in
                            model.updateSuggestions(for: .tag, text: text)
                        }
                    Button("Add") { commitTag() }
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                completions(.tag) { name in
                    model.addSearchTag(name)
                    newTag = ""
                }
            }

            if !model.unresolvedFilters.isEmpty {
                // The difference between "found nothing" and "was ignored".
                Label("Ignored — not recognised: \(model.unresolvedFilters.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let local = model.localDuration {
                    Label(timeText(local), systemImage: "clock")
                        .font(.caption).foregroundColor(.secondary)
                        .help("This file's running time — compare it against the results")
                }
                Spacer()
                Button {
                    Task { await model.runBrowse(page: 1) }
                } label: {
                    if model.isBrowsing { ProgressView().controlSize(.small) } else { Text("Search") }
                }
                .disabled(model.isBrowsing || !model.canBrowse)
            }
        }
        .padding()
    }

    /// Names the source actually recognises, offered as the filter is typed.
    ///
    /// Worth the space: these vocabularies belong to the source, and a filter
    /// it cannot resolve is silently not applied. Picking from the real list
    /// removes a whole class of "why did that do nothing".
    @ViewBuilder
    private func completions(_ kind: BrowseFilterKind, apply: @escaping (String) -> Void) -> some View {
        let names = model.suggestions[kind] ?? []
        if !names.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(names.prefix(8), id: \.self) { name in
                    Button { apply(name); model.clearSuggestions(for: kind) } label: {
                        Text(name).font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
        }
    }

    private func commitPerformer() {
        model.addSearchPerformer(newPerformer)
        newPerformer = ""
    }

    private func commitTag() {
        model.addSearchTag(newTag)
        newTag = ""
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if let error = model.browseError {
            ContentUnavailableView("Couldn't search", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if model.browseResults.isEmpty {
            ContentUnavailableView(
                model.isBrowsing ? "Searching…" : "Narrow it down",
                systemImage: "magnifyingglass",
                description: Text(model.isBrowsing
                    ? ""
                    : "Any filter will do — a studio on its own works when you don't know the cast. Adding one tag to it usually cuts hundreds of scenes down to a handful."))
        } else {
            List {
                Section {
                    ForEach(model.browseResults) { candidate in
                        row(candidate)
                    }
                } header: {
                    Text("Showing \(model.browseResults.count) of \(model.browseTotal)")
                } footer: {
                    if model.browseTotal > model.browseResults.count {
                        pager
                    }
                }
            }
        }
    }

    private var pager: some View {
        HStack {
            Button("Previous") { Task { await model.runBrowse(page: model.browsePage - 1) } }
                .disabled(model.browsePage <= 1 || model.isBrowsing)
            Spacer()
            Text("Page \(model.browsePage)").font(.caption).foregroundColor(.secondary)
            Spacer()
            Button("Next") { Task { await model.runBrowse(page: model.browsePage + 1) } }
                .disabled(model.isBrowsing
                          || model.browsePage * model.browseResults.count >= model.browseTotal)
        }
        .font(.caption)
    }

    private func row(_ candidate: PluginCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Tapping the image expands rather than selecting: recognising a
            // scene is a visual act, and one small still is rarely enough.
            Button { expanded = candidate } label: {
                ZStack(alignment: .bottomTrailing) {
                    thumbnail(candidate)
                    if candidate.imageURLs.count > 1 {
                        Text("\(candidate.imageURLs.count)")
                            .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.6)).foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(3)
                    }
                }
            }
            .buttonStyle(.plain)

            Button { onChoose(candidate) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).font(.subheadline).fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = candidate.subtitle {
                        Text(subtitle).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    durationLine(candidate)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    /// A near-identical running time is the strongest signal a person has here,
    /// so it is called out rather than left to be worked out from two numbers.
    @ViewBuilder
    private func durationLine(_ candidate: PluginCandidate) -> some View {
        if let duration = candidate.durationSeconds {
            let delta = model.durationDelta(for: candidate)
            HStack(spacing: 6) {
                Text(timeText(duration)).font(.caption2)
                if let delta {
                    if abs(delta) <= 25 {
                        Label("same length", systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundColor(.green)
                    } else {
                        Text(delta > 0 ? "+\(timeText(delta)) longer" : "\(timeText(-delta)) shorter")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
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
            .frame(width: 104, height: 59)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 104, height: 59)
                .overlay(Image(systemName: "film").foregroundColor(.secondary))
        }
    }

    private func timeText(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, s)
                       : String(format: "%d:%02d", m, s)
    }
}

/// Every image the source holds for one candidate, at a size worth looking at.
///
/// Separate from the row because the two answer different questions: a row asks
/// "is this worth a closer look", this asks "is this the one".
private struct CandidateGallery: View {
    let candidate: PluginCandidate
    var onChoose: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(candidate.imageURLs, id: \.self) { url in
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 140)
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
