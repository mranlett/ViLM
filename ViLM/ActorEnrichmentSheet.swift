// ActorEnrichmentSheet.swift
// The import flow's UI: disambiguation picker, then the proposed-changes diff.
//
// TRACKED and PUBLIC. Names no source — every label comes from the provider, so
// this file is identical regardless of which plugin is installed (D7/D9).

import SwiftUI
import LibraryCore

struct ActorEnrichmentSheet: View {

    @StateObject private var model: ActorEnrichmentModel
    @Environment(\.dismiss) private var dismiss

    let actorName: String
    /// Held for the context strip: the same "what does this record already say"
    /// block every other editing and matching screen shows.
    let entityId: String
    let currentProfile: EntityProfile?
    let libraryURL: URL?

    /// Remembered across sheets: someone who needs big pictures to tell
    /// performers apart needs them every time, and re-choosing on each lookup
    /// would be its own small annoyance.
    @AppStorage("pluginPickerLargeImages") private var showsLargeImages = false

    /// A candidate whose full set of images is being examined.
    ///
    /// One picture is often not enough to separate two similarly-named
    /// performers — especially the single-word names, where a search can return
    /// ten candidates and the text tells you nothing.
    @State private var examining: PluginCandidate?

    /// The name actually being searched for, which starts as the library's
    /// spelling and is editable.
    ///
    /// ⭐ Because the library's spelling is frequently the problem. A typo or a
    /// misspelling returns nothing, or returns the wrong people — and the fix
    /// was to cancel out, open the profile, rename globally, and start the
    /// match again. Four steps to correct one letter, at exactly the moment the
    /// operator can see it is wrong.
    ///
    /// ⚠️ Searching a different spelling changes NOTHING in the library. The
    /// rename happens only if a match is then accepted, through the existing
    /// canonical-name field — so trying three spellings costs nothing.
    @State private var searchTerm: String = ""
    @FocusState private var searchFieldFocused: Bool

    /// Show the proposed photos large.
    ///
    /// The default grid packs many small tiles, which is right for ticking
    /// through photos you already recognise — and wrong when you are trying to
    /// decide whether these images are even the right person. Remembered,
    /// because someone who needs the larger view needs it every time.
    @AppStorage("pluginReviewLargePhotos") private var showsLargePhotos = false
    /// Handed the merged profile when the user confirms. The caller puts the
    /// values in its fields; nothing is written to the library here.
    /// - Parameter renameTo: the source's canonical name, when the user chose to
    ///   adopt it. Handled separately from the profile because a rename is not a
    ///   field write — it changes the record's identity and every video's tag.
    let onApply: (EntityProfile, String?) -> Void

    init(provider: any ActorMetadataProvider,
         entityId: String,
         actorName: String,
         currentProfile: EntityProfile?,
         libraryURL: URL? = nil,
         onApply: @escaping (EntityProfile, String?) -> Void) {
        _model = StateObject(wrappedValue: ActorEnrichmentModel(
            provider: provider, entityId: entityId, currentProfile: currentProfile))
        self.entityId = entityId
        self.currentProfile = currentProfile
        self.libraryURL = libraryURL
        self.actorName = actorName
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextStrip
                content
            }
                .navigationTitle(model.provider.displayName)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // While reviewing a candidate that came from a picker,
                        // Cancel is the wrong exit: it discards the search and
                        // the next attempt re-queries the source for the same
                        // list. Offer the way back instead.
                        if case .reviewing = model.phase, model.canReturnToPicker {
                            Button {
                                model.returnToPicker()
                            } label: {
                                Label("Choose Someone Else", systemImage: "chevron.left")
                            }
                        } else {
                            Button("Cancel") { dismiss() }
                        }
                    }
                    if case .choosing = model.phase {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showsLargeImages.toggle()
                            } label: {
                                Image(systemName: showsLargeImages
                                      ? "list.bullet" : "square.grid.2x2.fill")
                            }
                            .help(showsLargeImages ? "Show as list" : "Show larger pictures")
                            .accessibilityLabel(showsLargeImages
                                                ? "Show as list" : "Show larger pictures")
                        }
                    }
                    if case .reviewing = model.phase {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Apply") {
                                if let profile = model.apply() {
                                    onApply(profile, model.acceptedCanonicalName)
                                }
                                dismiss()
                            }
                            .disabled(!model.canApply)
                        }
                    }
                }
                .task {
                    // Seeded once. Re-entering the sheet keeps whatever the
                    // operator last typed for this actor.
                    if searchTerm.isEmpty { searchTerm = actorName }
                    await model.search(name: actorName)
                }
        }
        .frame(minWidth: 380, minHeight: 480)
        .sheet(item: $examining) { candidate in
            candidatePhotoGrid(candidate)
        }
    }

    /// Every image a candidate has, large. The point is deciding WHO this is,
    /// so choosing is available from here without going back.
    @ViewBuilder
    private func candidatePhotoGrid(_ candidate: PluginCandidate) -> some View {
        NavigationStack {
            ScrollView {
                if let subtitle = candidate.subtitle {
                    Text(subtitle)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.top, 8)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(candidate.imageURLs, id: \.absoluteString) { url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fit)
                            case .failure:
                                placeholderFace
                            case .empty:
                                ZStack { Color.gray.opacity(0.1); ProgressView() }
                            @unknown default:
                                placeholderFace
                            }
                        }
                        .frame(minHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    Button("Back") { examining = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("This Person") {
                        examining = nil
                        Task { await model.choose(candidate) }
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 480)
    }

    /// Shown above every phase, so the record being matched is visible while
    /// choosing between candidates — not just afterwards while reviewing.
    /// Aliases especially: a lookup misses most often because the library files
    /// someone under a name the source does not use.
    @ViewBuilder
    private var contextStrip: some View {
        ActorContextPanel(entityId: entityId, profile: currentProfile, libraryURL: libraryURL)
            .padding(.horizontal)
            .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .searching:
            progress("Searching for \(searchedName)…")

        case .fetching:
            progress("Loading details…")

        case .choosing(let candidates):
            if showsLargeImages {
                candidateGallery(candidates)
            } else {
                candidatePicker(candidates)
            }

        case .reviewing(let review):
            reviewList(review)

        case .noMatches:
            VStack(spacing: 20) {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "person.fill.questionmark",
                    description: Text("\(model.provider.displayName) has no record under “\(searchedName)”. "
                                      + "If the name is misspelled here, correct it below and search again.")
                )
                respellRow
                    .frame(maxWidth: 420)
                markUnmatchableButton
            }

        case .nothingToApply:
            ContentUnavailableView(
                "Nothing to Add",
                systemImage: "checkmark.circle",
                description: Text("\(model.provider.displayName) has nothing this profile is missing.")
            )

        case .failed(let message):
            ContentUnavailableView(
                "Lookup Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private func progress(_ label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Disambiguation

    /// Several performers share a name. The photo is what makes this decidable
    /// at a glance — the text alone often cannot separate two records.
    private func candidatePicker(_ candidates: [PluginCandidate]) -> some View {
        List {
            Section {
                ForEach(candidates) { candidate in
                    Button {
                        Task { await model.choose(candidate) }
                    } label: {
                        HStack(spacing: 12) {
                            thumbnail(candidate.thumbnailURL)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.title).font(.body)
                                if let subtitle = candidate.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            if candidate.imageURLs.count > 1 {
                                Button {
                                    examining = candidate
                                } label: {
                                    Label("\(candidate.imageURLs.count)",
                                          systemImage: "photo.on.rectangle.angled")
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .overlay(Capsule().strokeBorder(.quaternary))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("See all \(candidate.imageURLs.count) photos")
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(candidates.count) performers match “\(searchedName)”")
            } footer: {
                Text("Pick the right one. Tap a photo count to see all of someone's pictures. "
                     + "Nothing is changed until you review and apply.")
            }

            Section {
                respellRow
            } header: {
                Text("Wrong person?")
            } footer: {
                Text("If none of these is right, the spelling here may be. Searching a different one changes nothing until you apply.")
            }

            Section {
                markUnmatchableButton
            } footer: {
                Text("Use this when none of these is the right person.")
            }
        }
    }

    /// Search under a different spelling.
    ///
    /// Offered in the two phases where a bad spelling reveals itself: no
    /// matches at all, and a list of candidates that are plainly other people.
    @ViewBuilder
    private var respellRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search for a different spelling", text: $searchTerm)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFieldFocused)
#if os(iOS)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
#endif
                    .onSubmit { Task { await research() } }
                Button("Search") { Task { await research() } }
                    .disabled(!canResearch)
            }
            Text(searchTerm.trimmingCharacters(in: .whitespacesAndNewlines) == actorName
                 ? "Correct a typo here rather than renaming the actor first — nothing changes in your library until you apply a match."
                 : "Searching “\(searchTerm)” instead of “\(actorName)”. Applying a match can rename the actor to the source's spelling.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// What the picker and progress lines should NAME. Saying "3 performers
    /// match Rowena Calder" while the results came from "Rowena Tiplin" is a
    /// screen lying about the question it asked.
    private var searchedName: String {
        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? actorName : trimmed
    }

    private var canResearch: Bool {
        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != actorName
    }

    private func research() async {
        searchFieldFocused = false
        await model.search(name: searchTerm.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Records the operator's judgement that this person is not in the source.
    ///
    /// Deliberately worded as a decision rather than a dismissal — it removes
    /// the actor from the attention queue permanently, and that should feel
    /// like a choice, not a way to close a dialog.
    private var markUnmatchableButton: some View {
        Button {
            onApply(model.markUnmatchable(), nil)
            dismiss()
        } label: {
            Label("Not in \(model.provider.displayName) — stop asking",
                  systemImage: "person.crop.circle.badge.xmark")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    /// The same choice, shown large.
    ///
    /// Two columns rather than three: the point is to see a face clearly enough
    /// to be sure, and three-up on a phone is barely larger than the list.
    private func candidateGallery(_ candidates: [PluginCandidate]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                ForEach(candidates) { candidate in
                    Button {
                        Task { await model.choose(candidate) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            // fullImageURL, not the thumbnail — upscaling a small
                            // image would make this view worse than the list it
                            // replaces.
                            AsyncImage(url: candidate.fullImageURL ?? candidate.thumbnailURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fill)
                                case .failure:
                                    placeholderFace
                                case .empty:
                                    ZStack { Color.gray.opacity(0.1); ProgressView() }
                                @unknown default:
                                    placeholderFace
                                }
                            }
                            .frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                            .overlay(alignment: .bottomTrailing) {
                                // Only when there IS more to see. Roughly half
                                // of performers carry a single image, so a badge
                                // on every card would promise nothing.
                                if candidate.imageURLs.count > 1 {
                                    Button {
                                        examining = candidate
                                    } label: {
                                        Label("\(candidate.imageURLs.count)",
                                              systemImage: "photo.on.rectangle.angled")
                                            .font(.caption).bold()
                                            .padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(.black.opacity(0.65), in: Capsule())
                                            .foregroundStyle(.white)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(8)
                                    .accessibilityLabel("See all \(candidate.imageURLs.count) photos")
                                }
                            }

                            HStack(spacing: 6) {
                                Text(candidate.title).font(.subheadline).bold()
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if candidate.imageURLs.count > 1 {
                                    Button {
                                        examining = candidate
                                    } label: {
                                        Label("\(candidate.imageURLs.count)",
                                              systemImage: "photo.on.rectangle.angled")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("See all \(candidate.imageURLs.count) photos")
                                }
                            }
                            if let subtitle = candidate.subtitle {
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

            Text("Pick the right one. Nothing is changed until you review and apply.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    private func thumbnail(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholderFace
            case .empty:
                ProgressView().controlSize(.small)
            @unknown default:
                placeholderFace
            }
        }
        .frame(width: 56, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private var placeholderFace: some View {
        ZStack {
            Color.gray.opacity(0.15)
            Image(systemName: "person.fill").foregroundStyle(.tertiary)
        }
    }

    // MARK: - Review

    private func reviewList(_ review: EnrichmentReview) -> some View {
        List {
            if let chosen = model.chosen {
                Section {
                    HStack(spacing: 12) {
                        thumbnail(chosen.thumbnailURL)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chosen.title).font(.headline)
                            if let subtitle = chosen.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Matched")
                    if model.canReturnToPicker {
                        Button {
                            model.returnToPicker()
                        } label: {
                            Label("Not this person — choose another",
                                  systemImage: "person.2.badge.gearshape")
                        }
                    }
                } footer: {
                    // Shown even when the picker was skipped, so the identity
                    // decision is never invisible.
                    Text(model.canReturnToPicker
                         ? "Check this is the right person. You can go back to the list without searching again."
                         : "Check this is the right person before applying.")
                }
            }

            if let proposed = model.proposedName, !model.renameWouldBeNoOp {
                Section {
                    Toggle(isOn: $model.acceptsCanonicalName) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.localName)
                                .font(.subheadline)
                                .strikethrough(model.acceptsCanonicalName)
                                .foregroundStyle(.secondary)
                            Label(proposed, systemImage: "arrow.turn.down.right")
                                .font(.subheadline).bold()
                        }
                    }
                } header: {
                    Text("Name")
                } footer: {
                    // Deliberately blunt, and more so now that this is ON by
                    // default: the merge case is the one people would otherwise
                    // discover after the fact rather than before.
                    Text("Renames this actor everywhere — every video's tag and every "
                         + "profile photo moves with it. **If “\(proposed)” already exists "
                         + "in your library, the two actors are merged into one.** "
                         + "Turn this off to keep your spelling.")
                }
            }

            if !review.fills.isEmpty {
                Section {
                    ForEach(review.fills) { row(($0)) }
                } header: {
                    Text("New Information")
                } footer: {
                    Text("These fields are empty today. Ticked by default.")
                }
            }

            if !review.conflicts.isEmpty {
                Section {
                    ForEach(review.conflicts) { row(($0)) }
                } header: {
                    Text("Disagreements")
                } footer: {
                    Text("Your value differs from \(review.sourceName)'s. "
                         + "Left unticked — tick one only if you want it overwritten.")
                }
            }

            if !model.galleryCandidates.isEmpty {
                Section {
                    photoGrid
                } header: {
                    HStack(spacing: 14) {
                        Text("Photos")
                        Spacer()
                        Button {
                            showsLargePhotos.toggle()
                        } label: {
                            Label(showsLargePhotos ? "Smaller" : "Larger",
                                  systemImage: showsLargePhotos
                                    ? "rectangle.grid.3x2" : "rectangle.grid.1x2")
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(showsLargePhotos
                                            ? "Show photos smaller" : "Show photos larger")

                        Button(model.allPhotosSelected ? "Select None" : "Select All") {
                            model.toggleAllPhotos()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                } footer: {
                    // None ticked by default: each photo is downloaded and stored
                    // per actor, so importing images nobody asked for is a cost
                    // the user did not choose.
                    Text(model.acceptedPhotos.isEmpty
                         ? "Tap the photos you want added to this actor's gallery. None are selected."
                         : "^[\(model.acceptedPhotos.count) photo](inflect: true) will be added. "
                           + "Existing photos are never replaced.")
                }
            }
        }
    }

    /// A grid rather than a list: choosing photos is a visual decision, and
    /// rows would show one face at a time.
    private var photoGrid: some View {
        // One or two per row when large, so a face is actually legible.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: showsLargePhotos ? 170 : 84),
                                     spacing: 8)], spacing: 8) {
            ForEach(model.galleryCandidates, id: \.absoluteString) { url in
                let isOn = model.acceptedPhotos.contains(url.absoluteString)
                Button {
                    model.togglePhoto(url)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                placeholderFace
                            case .empty:
                                ZStack { Color.gray.opacity(0.1); ProgressView().controlSize(.small) }
                            @unknown default:
                                placeholderFace
                            }
                        }
                        .frame(height: showsLargePhotos ? 260 : 112)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isOn ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                        // Barely dimmed when large: the selection state should
                        // not fight the job of SEEING the photo. The border and
                        // the checkmark already carry that signal.
                        .opacity(isOn ? 1 : (showsLargePhotos ? 0.92 : 0.65))

                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isOn ? Color.accentColor : Color.white.opacity(0.9))
                            .background(Circle().fill(.black.opacity(isOn ? 0 : 0.25)))
                            .padding(6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOn ? "Photo selected" : "Photo not selected")
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ change: ProposedChange) -> some View {
        Button {
            model.toggle(change.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.accepted.contains(change.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.accepted.contains(change.id) ? Color.accentColor : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(change.label).font(.subheadline).bold()

                    if let current = change.current {
                        // Only worth showing when something is at risk.
                        Text(current)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .strikethrough(change.kind == .conflict)
                    }
                    if let proposed = change.proposed {
                        Text(proposed)
                            .font(.caption)
                            .foregroundStyle(change.kind == .conflict ? Color.orange : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
