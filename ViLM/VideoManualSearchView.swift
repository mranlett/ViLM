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
    @State private var expanded: PluginCandidate?

    // Two independent axes, because they answer different questions:
    // "give the candidates more room" and "let me choose by picture".
    // Persisted — a preference about how you recognise a scene does not change
    // between videos, and re-setting it on every match would be its own chore.
    @AppStorage("videoMatchCompactFilters") private var compactFilters = false
    @AppStorage("videoMatchLargeImages") private var largeImages = false

    var body: some View {
        VStack(spacing: 0) {
            // Collapsed away entirely rather than merely shrunk: the subject
            // strip and the filter fields together take most of a phone screen,
            // and once a search has run they are reference material, not the
            // thing being looked at.
            if !compactFilters {
                subjectGrid
                filters
            }
            viewControls
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

    /// Always visible, including while the filters are collapsed — otherwise
    /// there is no way back to them.
    private var viewControls: some View {
        HStack(spacing: 12) {
            Button {
                compactFilters.toggle()
            } label: {
                Label(compactFilters ? "Show filters" : "Hide filters",
                      systemImage: compactFilters ? "chevron.down" : "chevron.up")
            }

            // When the filters are hidden, say what is still being applied.
            // A search silently narrowed by a filter you cannot see is the
            // fastest way to conclude the source has nothing.
            if compactFilters, !activeFilterSummary.isEmpty {
                Text(activeFilterSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button {
                largeImages.toggle()
            } label: {
                Label(largeImages ? "List" : "Large images",
                      systemImage: largeImages ? "list.bullet" : "square.grid.2x2")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if !model.searchPerformers.isEmpty { parts.append(model.searchPerformers.joined(separator: ", ")) }
        let studio = model.searchStudio.trimmingCharacters(in: .whitespacesAndNewlines)
        if !studio.isEmpty { parts.append(studio) }
        if !model.searchTags.isEmpty { parts.append(model.searchTags.joined(separator: ", ")) }
        let title = model.searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append("“\(title)”") }
        return parts.joined(separator: " · ")
    }

    /// The same context strip the editing screens use.
    private var subjectGrid: some View {
        VideoContextPanel(asset: model.subject, libraryURL: model.subjectLibraryURL)
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
                    // 🚨 Commit whatever is still sitting in the fields first.
                    //
                    // A name typed into "Add a performer…" and not confirmed
                    // with Add or Return was NOT a filter, so `canBrowse` was
                    // false, Search was silently greyed out, and pressing it did
                    // nothing — with the name visibly right there on screen.
                    // Reported twice as "search by hand is not working".
                    //
                    // ⭐ Pressing Search plainly means "search for what I have
                    // typed". Requiring a separate confirmation step first is a
                    // rule the screen never stated.
                    commitPending()
                    Task { await model.runBrowse(page: 1) }
                } label: {
                    if model.isBrowsing { ProgressView().controlSize(.small) } else { Text("Search") }
                }
                .disabled(model.isBrowsing || !canSearch)
                // ⚠️ A disabled control that does not say why teaches the
                // operator that the feature is broken.
                .help(canSearch ? "Search the source with these filters"
                                : "Add a performer, studio, tag or title to search for")
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

    /// Whether there is anything to search for, INCLUDING text still sitting
    /// uncommitted in a field.
    private var canSearch: Bool {
        model.canBrowse
            || !newPerformer.trimmingCharacters(in: .whitespaces).isEmpty
            || !newTag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Turns whatever is in the entry fields into filters.
    private func commitPending() {
        if !newPerformer.trimmingCharacters(in: .whitespaces).isEmpty { commitPerformer() }
        if !newTag.trimmingCharacters(in: .whitespaces).isEmpty { commitTag() }
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

    /// What an empty result actually means, in the three cases that produce one.
    ///
    /// ⭐ The middle case is the one that was missing: a search that ran and
    /// found nothing has to say so, and say what it searched WITH — because the
    /// most common cause is a filter the source did not recognise and therefore
    /// ignored, and that is fixable in five seconds once it is visible.
    private var emptyStateDetail: String {
        if model.isBrowsing { return "" }
        guard model.hasBrowsed else {
            return "Any filter will do — a studio on its own works when you don't know the cast. Adding one tag to it usually cuts hundreds of scenes down to a handful."
        }
        if !model.unresolvedFilters.isEmpty {
            return "The source did not recognise \(model.unresolvedFilters.joined(separator: ", ")), so \(model.unresolvedFilters.count == 1 ? "it was" : "they were") ignored. Try a different spelling, or remove \(model.unresolvedFilters.count == 1 ? "it" : "them") and narrow with something else."
        }
        return "The source has nothing matching every filter at once. Removing the narrowest one — usually a tag — is the quickest way to find out which is doing it."
    }

    @ViewBuilder
    private var results: some View {
        if let error = model.browseError {
            ContentUnavailableView("Couldn't search", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if model.browseResults.isEmpty {
            // 🚨 "Not searched yet" and "searched, found nothing" used to render
            // as the SAME empty state — both said "Narrow it down". A search
            // that ran and returned nothing was therefore indistinguishable
            // from one that never ran, which is how a working search gets
            // reported from the device as "it no longer searches".
            ContentUnavailableView(
                model.isBrowsing ? "Searching…"
                    : model.hasBrowsed ? "No matches" : "Narrow it down",
                systemImage: model.hasBrowsed && !model.isBrowsing
                    ? "magnifyingglass.circle" : "magnifyingglass",
                description: Text(emptyStateDetail))
        } else {
            if largeImages {
                imageGrid
            } else {
                List {
                    Section {
                        ForEach(model.browseResults) { candidate in
                            row(candidate)
                        }
                    } header: {
                        Text(showingLabel)
                    } footer: {
                        if model.hasNextBrowsePage || model.browsePage > 1 { pager }
                    }
                }
            }
        }
    }

    /// ⚠️ Says WHICH results these are, not merely how many.
    ///
    /// "Showing 25 of 235" is the same sentence on page 1 and page 5, so it
    /// answered a question nobody was asking while hiding the one they were.
    private var showingLabel: String {
        guard let range = model.browseRange else {
            return "Showing \(model.browseResults.count) of \(model.browseTotal)"
        }
        return range.lowerBound == range.upperBound
            ? "Showing \(range.lowerBound) of \(model.browseTotal)"
            : "Showing \(range.lowerBound)–\(range.upperBound) of \(model.browseTotal)"
    }

    /// Picture-first: a big still, and only enough text to break a tie.
    ///
    /// Recognising a scene is a visual act — the name a source gives it is
    /// often not the name you know it by, and a 104pt still is too small to
    /// recognise anything from. Tapping an image opens the full gallery;
    /// tapping the caption chooses, so a mis-tap looks rather than commits.
    private var imageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(model.browseResults) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { expanded = candidate } label: {
                            ZStack(alignment: .bottomTrailing) {
                                largeThumbnail(candidate)
                                if candidate.imageURLs.count > 1 {
                                    Text("\(candidate.imageURLs.count)")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.black.opacity(0.6), in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(6)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Button { onChoose(candidate) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title)
                                    .font(.caption).fontWeight(.medium)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                durationLine(candidate)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                Text(showingLabel).font(.caption).foregroundStyle(.secondary)
                if model.hasNextBrowsePage || model.browsePage > 1 { pager }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func largeThumbnail(_ candidate: PluginCandidate) -> some View {
        // Prefers the full-size image: the small one is what made picture-led
        // selection impossible in the first place.
        if let url = candidate.fullImageURL ?? candidate.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .overlay(Image(systemName: "film").foregroundColor(.secondary))
        }
    }

    private var pager: some View {
        HStack {
            Button("Previous") { Task { await model.runBrowse(page: model.browsePage - 1) } }
                .disabled(model.browsePage <= 1 || model.isBrowsing)
            Spacer()
            Text("Page \(model.browsePage)").font(.caption).foregroundColor(.secondary)
            Spacer()
            // Derived from the range's end, not from page × results-on-page,
            // which under-counts whenever a page comes back short and could
            // disable Next before the list had actually run out.
            Button("Next") { Task { await model.runBrowse(page: model.browsePage + 1) } }
                .disabled(model.isBrowsing || !model.hasNextBrowsePage)
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
        .macSheet(minWidth: 820, minHeight: 640)
    }
}
