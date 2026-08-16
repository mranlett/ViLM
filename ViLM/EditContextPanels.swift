// EditContextPanels.swift
// The context strip shown above every editing and matching screen.
//
// Four screens ask the operator to make decisions about a record — edit a
// video by hand, match a video to a source, edit an actor by hand, match an
// actor to a source — and every one of them needs the same thing: what does
// this record ALREADY say, and what does it look like. They had drifted into
// showing different subsets in different shapes, so the same question had a
// different answer depending on which door you came in by.
//
// Everything here is collapsed by default. The context is worth having within
// reach and is not worth pushing the actual form below the fold — a screen that
// opens on half a page of reference material makes the thing you came to do
// harder to find. Opening a section is one tap, and the closed row still
// carries a summary, so the common case needs no taps at all.

import SwiftUI
import LibraryCore

/// One collapsible strip of context.
///
/// The summary on the closed row is the part that earns its space: a file name
/// or an alias count answers most questions without expanding anything.
/// ⚠️ Hand-rolled rather than a `DisclosureGroup`, after two rounds of it
/// misbehaving on macOS.
///
/// 🚨 With a custom label, macOS makes only the disclosure TRIANGLE clickable —
/// and in a plain `VStack` it does not reliably draw one at all, so the rows
/// rendered as inert text. On iOS the whole row toggles natively, so both
/// failures were invisible everywhere they were tested.
///
/// Attaching a tap gesture to the label was the first fix and it was still at
/// the mercy of how `DisclosureGroup` handles interaction on each platform. A
/// `Button` plus conditional content behaves identically on both because there
/// is nothing platform-specific left in it.
struct ContextAccordion<Content: View>: View {
    let title: String
    let icon: String
    var summary: String?
    /// Defaults to closed everywhere. Passed in only so a caller can remember a
    /// per-screen preference later; nothing does yet, deliberately.
    @State var isExpanded: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.top, 6)
            }
        }
    }
}

// MARK: - Video

/// What the library already knows about a video, above any screen that edits it.
struct VideoContextPanel: View {
    let asset: Asset
    let libraryURL: URL?
    /// Frames are the expensive part — sixteen decodes — so a caller that has
    /// no use for them can leave them out rather than pay for a section nobody
    /// opens.
    var showsFrames: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ContextAccordion(title: "File name", icon: "doc.text",
                             summary: asset.fileName) {
                Text(asset.fileName)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsFrames {
                ContextAccordion(title: "Preview frames", icon: "square.grid.3x3",
                                 summary: nil) {
                    // Non-interactive: these screens have no player behind them
                    // to seek, so a tap would have nowhere to go. Reference
                    // while typing, not a scrubber.
                    DetailGridView(asset: asset, libraryURL: libraryURL, isInteractive: false)
                }
            }

            if !recorded.isEmpty {
                ContextAccordion(title: "Recorded", icon: "list.bullet.rectangle",
                                 summary: recordedSummary) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(recorded, id: \.0) { label, value in
                            HStack(alignment: .top, spacing: 6) {
                                Text(label).font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 74, alignment: .leading)
                                Text(value).font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Only what is actually set. A list of empty rows says nothing and pushes
    /// the real content down.
    private var recorded: [(String, String)] {
        var rows: [(String, String)] = []
        if let series = asset.videoName, !series.isEmpty { rows.append(("Series", series)) }
        if let season = asset.seasonNumber { rows.append(("Season", "\(season)")) }
        if let episode = asset.episodeNumber { rows.append(("Episode", "\(episode)")) }
        if let title = asset.episode, !title.isEmpty { rows.append(("Title", title)) }
        if let date = asset.releaseDate, !date.isEmpty { rows.append(("Released", date)) }
        if !asset.actors.isEmpty { rows.append(("Cast", asset.actors.joined(separator: ", "))) }
        if !asset.studios.isEmpty { rows.append(("Studio", asset.studios.joined(separator: ", "))) }
        if !asset.actions.isEmpty { rows.append(("Tags", asset.actions.joined(separator: ", "))) }
        return rows
    }

    private var recordedSummary: String {
        "\(recorded.count) field\(recorded.count == 1 ? "" : "s")"
    }
}

// MARK: - Actor

/// What the library already knows about an actor, above any screen that edits
/// them. The mirror of `VideoContextPanel`, deliberately the same shape.
struct ActorContextPanel: View {
    let entityId: String
    let profile: EntityProfile?
    let libraryURL: URL?

    /// Videos this library already has for this person.
    ///
    /// ⭐ The other half of disambiguation. The source's photos say who a
    /// CANDIDATE is; these say who the library already believes this person is
    /// — and comparing the two is what settles a choice that names and dates
    /// leave open. Somebody who recognises the work recognises the face.
    ///
    /// ⚠️ Loaded in `.task`, not computed. It is a database read per video and
    /// a computed property would re-run it on every redraw of the picker.
    @State private var localVideos: [Asset] = []

    /// ⚠️ Derived from the id, and correct only until the re-key.
    ///
    /// The panel receives an `entityId` and no profile. Fixing it means the
    /// caller passing the name it already holds — a signature change on a
    /// shared panel, so it is left for the pass that does the editors.
    private var displayName: String {
        entityId.hasPrefix("actor:") ? String(entityId.dropFirst(6)) : entityId
    }

    /// Primary first, then the gallery, deduplicated. The same order the
    /// profile page shows, so the two never disagree about which is the main
    /// photo.
    private var photoTokens: [String] {
        guard let profile else { return [] }
        var out: [String] = []
        if let primary = profile.photoUrl, !primary.isEmpty { out.append(primary) }
        for token in profile.galleryUrls where !out.contains(token) { out.append(token) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !photoTokens.isEmpty {
                ContextAccordion(title: "Photos", icon: "photo.on.rectangle",
                                 summary: "\(photoTokens.count)") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photoTokens, id: \.self) { token in
                                ProfileImageView(libraryURL: libraryURL, entityId: entityId,
                                                 photoUrl: token,
                                                 isGallery: token != (profile?.photoUrl ?? "")) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle().fill(Color.secondary.opacity(0.15))
                                }
                                .frame(width: 78, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }
            }

            if !localVideos.isEmpty {
                ContextAccordion(title: "In your library", icon: "film.stack",
                                 summary: "\(localVideos.count) video\(localVideos.count == 1 ? "" : "s")") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(localVideos) { asset in
                                VStack(alignment: .leading, spacing: 3) {
                                    VideoThumbnailView(asset: asset, libraryURL: libraryURL)
                                        .frame(width: 118, height: 66)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    Text(asset.fileName)
                                        .font(.system(size: 9)).lineLimit(2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 118, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }

            if let akas = profile?.akas, !akas.isEmpty {
                // The field a failed lookup most often turns on: a search misses
                // because the library records a name the source files under
                // something else.
                ContextAccordion(title: "Also known as", icon: "person.text.rectangle",
                                 summary: akas.joined(separator: ", ")) {
                    FlowLayout(spacing: 6) {
                        ForEach(akas, id: \.self) { aka in
                            Text(aka)
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.green.opacity(0.18))
                                .foregroundStyle(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if !recorded.isEmpty {
                ContextAccordion(title: "Recorded", icon: "list.bullet.rectangle",
                                 summary: "\(recorded.count) field\(recorded.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(recorded, id: \.0) { label, value in
                            HStack(alignment: .top, spacing: 6) {
                                Text(label).font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 74, alignment: .leading)
                                Text(value).font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .task(id: entityId) { await loadLocalVideos() }
    }

    /// The videos this library already credits to this person.
    ///
    /// ⚠️ Reads BOTH representations. `videoIds(forPerformer:)` answers from
    /// the edges, and a performer carried only by a `actor:` tag string — which
    /// is most of a library until the retirement step runs — would otherwise
    /// show none, making a person with a full filmography look like a stranger
    /// at exactly the moment their filmography is the evidence.
    ///
    /// ⚠️ Capped. This is a reference strip beside a picker, not a filmography
    /// page, and decoding several hundred assets to draw eight is work nobody
    /// asked for.
    private func loadLocalVideos() async {
        let name = displayName
        let id = entityId
        let urls = LibrarySession.shared.allURLs
        // ⚠️ Deliberately interactive — see QoSConventionTests for the rule and the reason.
        let found: [Asset] = await Task.detached(priority: .userInitiated) {
            var seen = Set<UUID>()
            var out: [Asset] = []
            for url in urls {
                guard let store = try? LibraryStore(at: url) else { continue }
                let edged = Set((try? store.videoIds(forPerformer: id)) ?? [])
                for asset in (try? store.fetchAllAssets()) ?? [] where out.count < 12 {
                    guard !seen.contains(asset.id) else { continue }
                    if edged.contains(asset.id)
                        || asset.actors.contains(where: {
                            $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        seen.insert(asset.id)
                        out.append(asset)
                    }
                }
            }
            return out
        }.value
        localVideos = found
    }

    private var recorded: [(String, String)] {
        guard let profile else { return [] }
        var rows: [(String, String)] = []
        if let gender = profile.gender, !gender.isEmpty { rows.append(("Gender", gender)) }
        if let birthDate = profile.birthDate, !birthDate.isEmpty {
            rows.append(("Born", birthDate))
        } else if let year = profile.birthYear {
            rows.append(("Born", "\(year)"))
        }
        if let country = profile.countryOfOrigin, !country.isEmpty {
            // ⭐ The flag is added HERE, not stored. Storing it split every
            // country into two values — see `CountryName`.
            rows.append(("Country", CountryFlagHelper.withFlag(country)))
        }
        if let hair = profile.hairColor, !hair.isEmpty { rows.append(("Hair", hair)) }
        if let career = profile.careerDisplay { rows.append(("Career", career)) }
        if !profile.tags.isEmpty { rows.append(("Tags", profile.tags.joined(separator: ", "))) }
        if !profile.links.isEmpty {
            rows.append(("Links", profile.links.map(\.displayLabel).joined(separator: ", ")))
        }
        if let state = profile.enrichmentState {
            rows.append(("Lookup", state.displayName))
        }
        return rows
    }
}
