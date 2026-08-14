// VideoHeadToHeadView.swift
// Head to Head — two videos, and one question (#38, D1).
//
// TRACKED and PUBLIC. Names no source.
//
// ⭐ The same mechanic, one subject later. The scoring, the pairing, the undo
// and the whole session are `HeadToHeadModel`, unchanged and shared; the chrome
// is `HeadToHeadBoard`, also shared. What is here is the part D1 says differs:
// how a contender is PRESENTED.
//
//   | Subject | Shows                | Tap advances through |
//   | Actor   | Primary photo        | Their gallery        |
//   | Video   | Contact-sheet frame  | The other frames     |
//
// 🚨 A video NEVER AUTOPLAYS here — and that is now a narrower claim than it
// once was. At the operator's direction a contender can be PLAYED and scrubbed
// deliberately, because a still cannot show motion and motion is often the
// thing being judged. What has not changed is that nothing starts on its own,
// and nothing is ever audible: see `ContenderVideoSurface`, which owns the
// player, keeps stills as the resting state, and is silent by construction.
//
// ⚠️ Titles are SHOWN, for the same reason performers' names are: the judgement
// being elicited is "which video", not "which frame", and a badly-chosen poster
// frame should not drag down a video the operator likes.

import SwiftUI
import LibraryCore
import ImageIO

struct VideoHeadToHeadView: View {
    let assets: [Asset]
    let entityProfiles: EntityProfileIndex
    /// Aliases resolved to canonical names, so the pool's actor filters mean
    /// here exactly what they mean in the grid.
    let akaMap: [String: String]
    let libraryURL: URL?

    @StateObject private var model = HeadToHeadModel()
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingPool = false
    @State private var isShowingStandings = false

    /// Which contenders have their cast revealed. Not cleared between pairs,
    /// for the same reason the actor game does not: an operator who opened it
    /// is telling us they want it open.
    @State private var expandedCast: Set<String> = []

    /// 🚨 The game's OWN pool, and its own storage key.
    ///
    /// The video grid already remembers a default filter, and reusing it would
    /// mean that browsing "unreviewed videos" silently changed who is in the
    /// game. Two intents, two settings — the same rule the actor game follows,
    /// and the reason this is not `defaultAssetFiltersStr`.
    ///
    /// ⚠️ Unfiltered by default, per D1b. A default that quietly narrows the
    /// field is how a ladder fragments without anyone noticing.
    @AppStorage("headToHeadVideoPoolStr") private var poolStr: String = ""
    private var pool: AssetFilterCriteria {
        guard let data = poolStr.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AssetFilterCriteria.self, from: data)
        else { return AssetFilterCriteria() }
        return decoded
    }
    private func setPool(_ criteria: AssetFilterCriteria) {
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
                        Button { isShowingPool = true } label: {
                            Label("What's playing", systemImage: pool.isEmpty
                                  ? "film.stack" : "film.stack.fill")
                        }
                    }
                }
                .task(id: poolStr) {
                    await model.loadVideos(assets: assets, profiles: entityProfiles,
                                           akaMap: akaMap, pool: pool,
                                           fallbackLibrary: libraryURL)
                }
                .sheet(isPresented: $isShowingStandings) {
                    PreferenceLeaderboardView(contenders: .videos(assets),
                                              libraryURL: libraryURL)
                }
                .sheet(isPresented: $isShowingPool) {
                    VideoPoolPicker(initial: pool, assets: assets,
                                    entityProfiles: entityProfiles, onApply: setPool)
                }
        }
        .macSheet(minWidth: 720, minHeight: 560)
    }

    private var board: some View {
        HeadToHeadBoard(model: model,
                        poolIsFiltered: !pool.isEmpty,
                        poolBannerText: "Playing \(model.poolCount) of your videos",
                        poolBannerSymbol: "film.stack.fill",
                        emptySymbol: "film.stack",
                        onOpenPool: { isShowingPool = true }) { side, outcome in
            contender(side, choosing: outcome)
        }
    }

    // MARK: - One contender

    @ViewBuilder
    private func contender(_ side: HeadToHeadModel.Side,
                           choosing outcome: PreferenceOutcome) -> some View {
        if let asset = side.asset {
            VStack(spacing: 8) {
                // ⚠️ No tap gesture out here. The surface owns its own taps —
                // a gesture on the container would sit on top of the player's
                // scrubber and swallow every attempt to drag it.
                ContenderVideoSurface(asset: asset,
                                      stillIndex: side.galleryIndex,
                                      onBrowse: { model.browse(side) })

                Text(side.name)
                    .font(.headline)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                // ⭐ The video's own equivalent of "known for": who made it and
                // when. Studio and year are what tell two similar-looking
                // scenes apart, and the frame alone cannot.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(asset.studios.prefix(2), id: \.self) { studio in
                        Text("· \(studio)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if let year = releaseYear(of: asset) {
                        Text("· \(year)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    castDisclosure(asset, sideId: side.id)
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)

                if expandedCast.contains(side.id) {
                    castStrip(for: asset)
                }

                HeadToHeadChooseButton { model.choose(outcome) }
            }
        }
    }

    /// ⚠️ The YEAR only. A release date is stored as a string of varying
    /// precision, and rendering whatever it happens to hold would put a full
    /// ISO date under one contender and a bare year under the other.
    private func releaseYear(of asset: Asset) -> String? {
        guard let date = asset.releaseDate, date.count >= 4 else { return nil }
        let year = String(date.prefix(4))
        return year.allSatisfy(\.isNumber) ? year : nil
    }

    @ViewBuilder
    private func castDisclosure(_ asset: Asset, sideId: String) -> some View {
        if !asset.actors.isEmpty {
            Button {
                if expandedCast.contains(sideId) {
                    expandedCast.remove(sideId)
                } else {
                    expandedCast.insert(sideId)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: expandedCast.contains(sideId)
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text(asset.actors.count == 1
                         ? "1 performer" : "\(asset.actors.count) performers")
                        .font(.caption2)
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Who is in it, with faces where the library has them.
    ///
    /// ⭐ The mirror of the actor game's video strip: there, the evidence for
    /// judging a performer is the videos they are in; here, the evidence for
    /// judging a video is who is in it.
    ///
    /// ⚠️ Names are resolved through `akaMap` exactly as the pool filter is, so
    /// a performer credited under an alias still shows their own face rather
    /// than a placeholder.
    @ViewBuilder
    private func castStrip(for asset: Asset) -> some View {
        let names = asset.actors.map { akaMap[$0] ?? $0 }.prefix(stripLimit)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(names), id: \.self) { name in
                    let profile = entityProfiles[actor: name]
                    VStack(alignment: .leading, spacing: 3) {
                        ProfileImageView(libraryURL: profile.flatMap {
                                            LibrarySession.shared.url(forProfile: $0.id)
                                         } ?? libraryURL,
                                         entityId: profile?.id ?? "actor:\(name)",
                                         photoUrl: profile?.photoUrl) { image in
                            Color.clear.overlay(image.resizable().scaledToFill(), alignment: .top)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15))
                                .overlay(Image(systemName: "person.fill")
                                    .font(.system(size: 16)).foregroundStyle(.secondary))
                        }
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(width: 54, alignment: .leading)
                    }
                }
                // ⚠️ Whatever is cut is COUNTED and said out loud, so the strip
                // never contradicts the number above it.
                if asset.actors.count > stripLimit {
                    Text("+\(asset.actors.count - stripLimit)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(height: 54)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stripLimit: Int { 8 }
}

/// Chooses what is in the game, reusing the video grid's filter builder.
///
/// ⭐ D1b again: `AssetFilterCriteria`, its matcher and its builder already
/// exist and are already shared, so the game gets studio, series, tag and cast
/// filters without inventing any of them.
///
/// ⚠️ Applied on dismissal rather than live, so the pairing does not shuffle
/// underneath the operator while they are still deciding.
private struct VideoPoolPicker: View {
    let initial: AssetFilterCriteria
    let assets: [Asset]
    let entityProfiles: EntityProfileIndex
    let onApply: (AssetFilterCriteria) -> Void

    @State private var criteria: AssetFilterCriteria

    init(initial: AssetFilterCriteria, assets: [Asset],
         entityProfiles: EntityProfileIndex,
         onApply: @escaping (AssetFilterCriteria) -> Void) {
        self.initial = initial
        self.assets = assets
        self.entityProfiles = entityProfiles
        self.onApply = onApply
        _criteria = State(initialValue: initial)
    }

    var body: some View {
        FilterBuilderView(assets: assets, criteria: $criteria,
                          actorProfiles: entityProfiles)
            .onDisappear { onApply(criteria) }
    }
}
