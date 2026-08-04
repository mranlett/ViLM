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

    /// Show the proposed photos large.
    ///
    /// The default grid packs many small tiles, which is right for ticking
    /// through photos you already recognise — and wrong when you are trying to
    /// decide whether these images are even the right person. Remembered,
    /// because someone who needs the larger view needs it every time.
    @AppStorage("pluginReviewLargePhotos") private var showsLargePhotos = false
    /// Handed the merged profile when the user confirms. The caller puts the
    /// values in its fields; nothing is written to the library here.
    let onApply: (EntityProfile) -> Void

    init(provider: any ActorMetadataProvider,
         entityId: String,
         actorName: String,
         currentProfile: EntityProfile?,
         onApply: @escaping (EntityProfile) -> Void) {
        _model = StateObject(wrappedValue: ActorEnrichmentModel(
            provider: provider, entityId: entityId, currentProfile: currentProfile))
        self.actorName = actorName
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            content
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
                                if let profile = model.apply() { onApply(profile) }
                                dismiss()
                            }
                            .disabled(!model.canApply)
                        }
                    }
                }
                .task { await model.search(name: actorName) }
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .searching:
            progress("Searching for \(actorName)…")

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
            ContentUnavailableView(
                "No Matches",
                systemImage: "person.fill.questionmark",
                description: Text("\(model.provider.displayName) has no record under “\(actorName)”. "
                                  + "If this actor is known by another name, try renaming or adding an AKA.")
            )

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
                Text("\(candidates.count) performers match “\(actorName)”")
            } footer: {
                Text("Pick the right one. Tap a photo count to see all of someone's pictures. "
                     + "Nothing is changed until you review and apply.")
            }
        }
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
