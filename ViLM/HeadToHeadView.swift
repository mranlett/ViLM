// HeadToHeadView.swift
// Head to Head — two contenders, and one question (#34).
//
// TRACKED and PUBLIC. Names no source.
//
// ⭐ The design constraints here are from the spec and are not decoration:
//
//   • The next pair is PREFETCHED. A wait between taps ends a session faster
//     than anything else, so the model chooses the following pair before it is
//     needed.
//   • No score is shown mid-game. The moment it feels like a test it stops
//     being a game. The session tally is a count of taps, not a judgement.
//   • Endless and stoppable (D5). There is no run length and nothing pending,
//     so leaving at any point loses nothing.
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
            content
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
                    enlargedStill(asset)
                }
                .sheet(isPresented: $isShowingStandings) {
                    PreferenceLeaderboardView(entityProfiles: entityProfiles,
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
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            centred { ProgressView("Gathering contenders…") }

        case .unplayable(let reason):
            // T12 — a refusal that says why, rather than an empty board.
            centred {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Nothing to compare").font(.title3.bold())
                Text(reason)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

        case .failed(let message):
            centred {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(.orange)
                Text(message).font(.callout).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

        case .playing(let left, let right):
            VStack(spacing: 12) {
                poolBanner
                // ⚠️ Horizontal on both platforms. Two contenders stacked
                // vertically on a phone cannot be compared without scrolling,
                // and a comparison you have to scroll to make is not a rapid
                // visual judgement.
                HStack(alignment: .top, spacing: 12) {
                    contender(left, choosing: .left)
                    contender(right, choosing: .right)
                }
                .padding(.horizontal, 12)

                secondaryAnswers
                footer
            }
            .padding(.vertical, 12)
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

    /// The still, full size, with every contact-sheet frame behind it.
    ///
    /// ⭐ Tap advances. A contact sheet is ONE composite image, so the frames
    /// are sliced out of it with `ContactSheetLayout` — the inverse of the
    /// geometry that composed it — rather than re-extracted from the video,
    /// which would mean an AVFoundation pass per look.
    ///
    /// ⚠️ The poster frame comes FIRST. It is the image the operator tapped,
    /// and opening onto a different one would read as the wrong video.
    @ViewBuilder
    private func enlargedStill(_ asset: Asset) -> some View {
        StillBrowser(asset: asset) { enlarged = nil }
    }

    /// ⚠️ Bounded. A performer with two hundred videos would otherwise build
    /// two hundred thumbnail views inside a card the operator scrolls past in
    /// a second.
    private var stripLimit: Int { 12 }

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

                // ⭐ Only when there IS more to see. A control that does
                // nothing teaches the operator to ignore the control.
                if side.hasMoreThanOneImage {
                    Label("\(side.galleryIndex % side.images.count + 1)/\(side.images.count)",
                          systemImage: "photo.on.rectangle")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
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
                        if expandedVideos.contains(side.profile.id) {
                            expandedVideos.remove(side.profile.id)
                        } else {
                            expandedVideos.insert(side.profile.id)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: expandedVideos.contains(side.profile.id)
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

            if expandedVideos.contains(side.profile.id) {
                videoStrip(for: side)
            }

            Button {
                model.choose(outcome)
            } label: {
                Text("Choose").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // ⚠️ Large and reachable. This is the control pressed on every
            // single comparison, and it is the one the whole session's pace
            // depends on.
            .controlSize(.large)
        }
    }

    // MARK: - The other two answers

    private var secondaryAnswers: some View {
        HStack(spacing: 16) {
            // D6 — a draw is an ANSWER. Forcing a choice between two
            // contenders rated equally injects noise into every score they
            // touch.
            Button("Too close to call") { model.choose(.draw) }
                .buttonStyle(.bordered)

            // D6 — and "neither" means something different: neither belongs in
            // the ranking. No confirmation; undo is the safety net.
            Button("Neither", role: .destructive) { model.retireBoth() }
                .buttonStyle(.bordered)
        }
        .font(.callout)
    }

    /// ⚠️ Always visible when a pool is set. D1b's warning is that a filtered
    /// session quietly produces a ladder that cannot be compared with an
    /// unfiltered one; the mitigation the spec asks for is to SAY SO rather
    /// than to prevent it.
    @ViewBuilder
    private var poolBanner: some View {
        if !pool.isEmpty {
            Button { isShowingPool = true } label: {
                Label("Playing \(model.poolCount) of your performers", systemImage: "person.3.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canUndo && !model.canUndoRetirement)

            Spacer()

            // D5 — a tally, not a target. "14 of 20" would make stopping at
            // seven feel like waste, which is the opposite of what a
            // low-friction elicitation tool wants.
            Text(model.comparedThisSession == 1
                 ? "1 compared this session"
                 : "\(model.comparedThisSession) compared this session")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func centred<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(spacing: 10) { body() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The poster frame plus every contact-sheet frame, one at a time.
///
/// 🚨 Slices the sheet rather than re-extracting frames. A contact sheet is a
/// single composite JPEG already on disk; pulling twelve frames out of the
/// video again would mean an AVFoundation pass every time someone glanced at a
/// contender, on a screen whose whole point is speed.
///
/// ⚠️ Loaded off the main actor and only when opened. Twelve full-size crops
/// per contender, built eagerly for both sides of every pair, is exactly the
/// kind of work that makes a game feel heavy.
private struct StillBrowser: View {
    let asset: Asset
    let onClose: () -> Void

    @State private var frames: [CGImage] = []
    @State private var index = 0
    @State private var isLoading = true

    private var total: Int { frames.count }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if frames.isEmpty {
                    // ⚠️ Says why rather than showing an empty black screen.
                    // A video with no contact sheet yet is the common case for
                    // anything added recently.
                    ContentUnavailableView("No stills yet",
                                           systemImage: "photo.on.rectangle",
                                           description: Text("This video has no contact sheet. Generate one from the video's own page and its frames will appear here."))
                } else {
                    Image(decorative: frames[index], scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // ⭐ Tap anywhere advances, wrapping. This is a look,
                        // not a screen to navigate — the game's pace depends
                        // on getting through it without aiming at controls.
                        .contentShape(Rectangle())
                        .onTapGesture { index = (index + 1) % total }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
            .navigationTitle(total > 1 ? "\(index + 1) of \(total)" : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(ActorKnownFor.displayTitle(asset))
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal).padding(.bottom, 8)
            }
        }
        .macSheet(minWidth: 720, minHeight: 480)
        .task { await load() }
    }

    private func load() async {
        let posterURL = LibrarySession.shared.thumbnailURL(for: asset.id)
        let sheetURL = LibrarySession.shared.contactSheetURL(for: asset.id)

        let loaded: [CGImage] = await Task.detached(priority: .userInitiated) {
            var out: [CGImage] = []
            // The poster first — it is the image that was tapped.
            if let posterURL, let poster = Self.image(at: posterURL) { out.append(poster) }
            if let sheetURL, let sheet = Self.image(at: sheetURL) {
                let size = CGSize(width: sheet.width, height: sheet.height)
                for rect in ContactSheetLayout.pixelCells(forSheetOfSize: size) {
                    // ⚠️ `cropping` returns nil for a rect outside the image,
                    // which is the correct answer for a sheet laid out
                    // differently from today's constants — skip, never crash.
                    if let cell = sheet.cropping(to: rect) { out.append(cell) }
                }
            }
            return out
        }.value

        frames = loaded
        isLoading = false
    }

    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
