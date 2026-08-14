// HeadToHeadView.swift
// Head to Head — two performers, and one question (#34).
//
// TRACKED and PUBLIC. Names no source.
//
// ⭐ The chrome around the two cards — the refusal, the secondary answers, the
// undo and the tally — is `HeadToHeadBoard`, shared with the video game (#38).
// What lives here is what is specific to judging a PERFORMER: the photo and its
// gallery, what the library knows them for, and the actor-shaped pool.
//
// ⚠️ Gesture split, at the operator's direction: tapping a PHOTO browses that
// contender's gallery; an explicit Choose button commits. It costs one tap per
// comparison against tap-to-choose, and buys an answer that can never be given
// by accident while looking through pictures.
//
// ⚠️ Names are SHOWN, also at the operator's direction. The judgement being
// elicited is "which performer", not "which photograph" — which is what the
// downstream recommendation work needs, and it means a poor photo of someone
// well-liked no longer drags them down.

import SwiftUI
import LibraryCore
import ImageIO

struct HeadToHeadView: View {
    let entityProfiles: EntityProfileIndex
    let assets: [Asset]
    let profileImageFileNames: Set<String>
    let allUniqueGenders: [String]
    let allUniqueHairColors: [String]
    let allUniqueCountries: [String]
    let allUniqueTags: [String]
    let libraryURL: URL?

    @StateObject private var model = HeadToHeadModel()
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingPool = false
    @State private var isShowingStandings = false

    /// Which contenders have their videos revealed.
    ///
    /// ⚠️ Keyed by profile id and NOT cleared between pairs on purpose: an
    /// operator who opened the strip is telling us they want to see it, and
    /// re-collapsing it every round would make the affordance useless at the
    /// pace this screen is played at.
    @State private var expandedVideos: Set<String> = []

    /// The still being shown full size.
    @State private var enlarged: Asset?

    /// The contender whose photo is being shown full screen.
    ///
    /// ⭐ Added with the video game's playback work: the operator asked to
    /// expand pictures as well as videos, and a performer's photo is the
    /// picture this half of the game is judged on.
    @State private var enlargedPhoto: HeadToHeadModel.Side?

    /// 🚨 The game's OWN pool, not the actor grid's saved default.
    ///
    /// The grid already remembers a default filter, and reusing it would mean
    /// that browsing "actors missing a photo" silently changed who is in the
    /// game. Two intents, two settings.
    ///
    /// ⚠️ Unfiltered by default, per D1b — a default that quietly narrows the
    /// field is how a ladder fragments without anyone noticing. Set once, it
    /// persists, and the header below always says what it is.
    @AppStorage("headToHeadPoolStr") private var poolStr: String = ""
    private var pool: ActorFilterCriteria {
        guard let data = poolStr.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ActorFilterCriteria.self, from: data)
        else { return ActorFilterCriteria() }
        return decoded
    }
    private func setPool(_ criteria: ActorFilterCriteria) {
        poolStr = (try? JSONEncoder().encode(criteria))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        NavigationStack {
            board
                .navigationTitle("Head to Head")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { isShowingStandings = true } label: {
                            Label("Standings", systemImage: "trophy")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isShowingPool = true
                        } label: {
                            Label("Who's playing", systemImage: pool.isEmpty
                                  ? "person.3" : "person.3.fill")
                        }
                    }
                }
                .task(id: poolStr) {
                    await model.load(profiles: entityProfiles, assets: assets,
                                     photoFileNames: profileImageFileNames,
                                     pool: pool, fallbackLibrary: libraryURL)
                }
                // ⭐ The still, at the size it is actually judged at. Tapping
                // anywhere dismisses — this is a look, not a screen to
                // navigate, and the game's pace depends on getting back fast.
                .sheet(item: $enlarged) { asset in
                    StillBrowser(asset: asset) { enlarged = nil }
                }
                // Full screen on a phone, a sheet on the desktop — the same
                // rule the video card's expand follows.
                .fullScreenCoverOnPhone(isPresented: Binding(
                    get: { enlargedPhoto != nil },
                    set: { if !$0 { enlargedPhoto = nil } }
                )) {
                    if let side = enlargedPhoto, let profile = side.profile {
                        FullScreenPhotoBrowser(
                            libraryURL: side.libraryURL,
                            entityId: side.id,
                            primaryPhotoUrl: profile.photoUrl,
                            identifiers: photoIdentifiers(for: side),
                            initialIdentifier: currentPhotoIdentifier(for: side),
                            onClose: { enlargedPhoto = nil })
                    }
                }
                .sheet(isPresented: $isShowingStandings) {
                    PreferenceLeaderboardView(contenders: .actors(entityProfiles),
                                              libraryURL: libraryURL)
                }
                .sheet(isPresented: $isShowingPool) {
                    PoolPicker(initial: pool,
                               allUniqueGenders: allUniqueGenders,
                               allUniqueHairColors: allUniqueHairColors,
                               allUniqueCountries: allUniqueCountries,
                               allUniqueTags: allUniqueTags,
                               onApply: setPool)
                }
        }
        // ⚠️ `.macSheet`, not a raw frame. This screen carried one since #34
        // and escaped the standard's automated check only because it is
        // presented through a computed property the scan cannot see — which is
        // the check's own blind spot, not a licence.
        .macSheet(minWidth: 720, minHeight: 560)
    }

    private var board: some View {
        HeadToHeadBoard(model: model,
                        poolIsFiltered: !pool.isEmpty,
                        poolBannerText: "Playing \(model.poolCount) of your performers",
                        poolBannerSymbol: "person.3.fill",
                        emptySymbol: "person.2.slash",
                        onOpenPool: { isShowingPool = true }) { side, outcome in
            contender(side, choosing: outcome)
        }
    }

    // MARK: - One contender

    /// The contender's videos from YOUR library, as stills.
    ///
    /// ⭐ Ids come from `knownFor`, which produced the count above them in the
    /// same pass — so the strip can never disagree with the number the operator
    /// just read. Filtering `assets` here by name would re-express the
    /// AKA-crediting rule and drift from it.
    @ViewBuilder
    private func videoStrip(for side: HeadToHeadModel.Side) -> some View {
        let byId = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shown = side.knownFor.videos.prefix(stripLimit)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(shown), id: \.id) { ref in
                    if let asset = byId[ref.id] {
                        Button {
                            enlarged = asset
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                VideoThumbnailView(asset: asset,
                                                   libraryURL: LibrarySession.shared.url(for: asset.id))
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(ref.title)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(width: 96, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                // ⚠️ Whatever is cut is COUNTED and said out loud. A strip that
                // quietly stops reads as a performer with fewer videos than the
                // line above it just claimed.
                if side.knownFor.videos.count > stripLimit {
                    Text("+\(side.knownFor.videos.count - stripLimit)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(height: 54)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ Bounded. A performer with two hundred videos would otherwise build
    /// two hundred thumbnail views inside a card the operator scrolls past in
    /// a second.
    private var stripLimit: Int { 12 }

    /// The browser addresses photos by token: "primary", then each gallery url.
    ///
    /// ⚠️ Built from `Side.images`, which is what the card itself is paging
    /// through — so the full-screen browser opens on the picture actually on
    /// screen rather than on the first one.
    private func photoIdentifiers(for side: HeadToHeadModel.Side) -> [String] {
        ["primary"] + side.images.dropFirst().compactMap { $0 }
    }

    private func currentPhotoIdentifier(for side: HeadToHeadModel.Side) -> String {
        let identifiers = photoIdentifiers(for: side)
        guard !identifiers.isEmpty else { return "primary" }
        return identifiers[side.galleryIndex % identifiers.count]
    }

    private func contender(_ side: HeadToHeadModel.Side,
                           choosing outcome: PreferenceOutcome) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ProfileImageView(libraryURL: side.libraryURL,
                                 entityId: side.id,
                                 photoUrl: side.currentImage,
                                 isGallery: side.galleryIndex > 0) { image in
                    Color.clear.overlay(image.resizable().scaledToFill(), alignment: .top)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "person.fill")
                            .font(.system(size: 44)).foregroundStyle(.secondary))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onTapGesture { model.browse(side) }

                HStack(spacing: 6) {
                    // ⭐ Only when there IS more to see. A control that does
                    // nothing teaches the operator to ignore the control.
                    if side.hasMoreThanOneImage {
                        Label("\(side.galleryIndex % side.images.count + 1)/\(side.images.count)",
                              systemImage: "photo.on.rectangle")
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    // The same expand affordance, in the same corner, as the
                    // video card's — one gesture to learn across both games.
                    Button {
                        enlargedPhoto = side
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Full screen")
                }
                .padding(8)
            }

            // Names shown — the judgement is about the performer.
            Text(side.name)
                .font(.headline)
                .lineLimit(2).minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // ⭐ What the library knows them for, at the operator's direction.
            // The photo shrank to make room, which is the right trade once it
            // is a reminder of WHO this is rather than the thing being judged.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(side.knownFor.titles, id: \.self) { title in
                    Text("· \(title)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                if side.knownFor.videoCount > 0 {
                    // ⚠️ A popularity signal in a preference judgement, shown
                    // at the operator's explicit choice after being told. A
                    // DELIBERATE trade, not an oversight.
                    //
                    // ⭐ Now a disclosure, matching "Known for" in the actor
                    // disambiguation sheet — same chevron, same reveal, same
                    // horizontal strip of stills. The difference is the source
                    // of the evidence: there it is the provider's scenes, here
                    // it is YOUR library.
                    Button {
                        if expandedVideos.contains(side.id) {
                            expandedVideos.remove(side.id)
                        } else {
                            expandedVideos.insert(side.id)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: expandedVideos.contains(side.id)
                                  ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9))
                            Text(side.knownFor.videoCount == 1
                                 ? "1 video" : "\(side.knownFor.videoCount) videos")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)

            if expandedVideos.contains(side.id) {
                videoStrip(for: side)
            }

            HeadToHeadChooseButton { model.choose(outcome) }
        }
    }
}

/// Chooses who is in the game, reusing the actor grid's filter builder.
///
/// ⭐ D1b's "almost no new work" argument, honoured literally: the criteria,
/// the matcher and the builder already exist and are already shared, so the
/// game gets a pool step without inventing one. A filter therefore means the
/// same thing here as it does when browsing.
///
/// ⚠️ Applied on dismissal rather than live. Rebuilding the pool on every
/// keystroke would re-pair the game underneath the operator while they are
/// still deciding who should be in it.
private struct PoolPicker: View {
    let initial: ActorFilterCriteria
    let allUniqueGenders: [String]
    let allUniqueHairColors: [String]
    let allUniqueCountries: [String]
    let allUniqueTags: [String]
    let onApply: (ActorFilterCriteria) -> Void

    @State private var criteria: ActorFilterCriteria
    @Environment(\.dismiss) private var dismiss

    init(initial: ActorFilterCriteria,
         allUniqueGenders: [String], allUniqueHairColors: [String],
         allUniqueCountries: [String], allUniqueTags: [String],
         onApply: @escaping (ActorFilterCriteria) -> Void) {
        self.initial = initial
        self.allUniqueGenders = allUniqueGenders
        self.allUniqueHairColors = allUniqueHairColors
        self.allUniqueCountries = allUniqueCountries
        self.allUniqueTags = allUniqueTags
        self.onApply = onApply
        _criteria = State(initialValue: initial)
    }

    var body: some View {
        ActorFilterBuilderView(allUniqueGenders: allUniqueGenders,
                               allUniqueHairColors: allUniqueHairColors,
                               allUniqueCountries: allUniqueCountries,
                               allUniqueTags: allUniqueTags,
                               criteria: $criteria)
            .onDisappear { onApply(criteria) }
    }
}
