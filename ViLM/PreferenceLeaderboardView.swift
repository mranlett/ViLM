// PreferenceLeaderboardView.swift
// Head to Head — the standings (#35, #38).
//
// TRACKED and PUBLIC. Names no source.
//
// ⭐ This is the feature's actual output, not a readout of it. The spec says a
// leaderboard worth reaching is the reason to keep playing, and that the top
// tier is what the Dashboard and the outward-looking work both need first.
//
// 🚨 The honesty rules are the whole design here, and they come from D8:
//
//   • A contender below the confidence threshold is SETTLING, not ranked. It
//     shows its comparison count instead of a position, and earns no star. A
//     score from three comparisons presented like a score from thirty is the
//     fastest way to make the ranking untrustworthy.
//   • Stars are DERIVED from the distribution and recomputed every time this
//     opens — never awarded, never stored.
//   • A filtered pool is stated. Scores between contenders that have never met
//     are not really comparable, and the spec's chosen mitigation is to say so
//     rather than to pretend otherwise.
//
// ⭐ One board for both subjects (D1). What changes is the picture beside a row
// and the noun in the footer; the ranking, the threshold and the derived stars
// are the same rules and are computed once, here.

import SwiftUI
import LibraryCore

struct PreferenceLeaderboardView: View {
    /// Who is being ranked, and therefore how a row is drawn.
    enum Contenders {
        case actors(EntityProfileIndex)
        case videos([Asset])

        var subject: PreferenceSubject {
            switch self {
            case .actors: return .actor
            case .videos: return .video
            }
        }
    }

    let contenders: Contenders
    let libraryURL: URL?

    /// Opens the contender behind a row: a performer's profile, or a video.
    ///
    /// ⭐ The board was a dead end without it (#69) — it names a leader, shows
    /// their picture and their stars, and offered nothing to do with any of it.
    /// The second argument is the FULL on-screen order, so a video can be
    /// opened with the standings as its context and paging goes to the next
    /// contender rather than into whatever the grid happened to be sorted by.
    ///
    /// ⚠️ Optional. Nil leaves the rows inert, so a caller that has nowhere to
    /// send the operator does not offer a tap that does nothing.
    var onReveal: ((Standing, [Standing]) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var ranked: [Standing] = []
    @State private var settling: [Standing] = []
    @State private var isLoading = true

    struct Standing: Identifiable {
        let id: String
        let name: String
        let kind: Kind
        let libraryURL: URL?
        let comparisons: Int
        /// Nil while provisional — D8. Absent rather than low, because "not yet
        /// known" and "known to be poor" are different claims.
        let stars: Int?

        enum Kind {
            case actor(EntityProfile)
            case video(Asset)
        }
    }

    /// The noun the footers use, so a board of videos does not talk about
    /// performers.
    private var subjectNoun: (singular: String, plural: String) {
        switch contenders {
        case .actors: return ("performer", "performers")
        case .videos: return ("video", "videos")
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Standings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { load() }
        }
        .macSheet(minWidth: 460, minHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if ranked.isEmpty && settling.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "trophy").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("No standings yet").font(.title3.bold())
                Text("Play a few rounds of Head to Head and your ranking will build itself.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !ranked.isEmpty {
                    Section {
                        ForEach(Array(ranked.enumerated()), id: \.element.id) { index, standing in
                            row(standing, position: index + 1)
                        }
                    } header: {
                        Text("Ranked")
                    } footer: {
                        // ⚠️ Stated, not implied. Two contenders that have never
                        // met are only loosely comparable however tidy the list
                        // looks.
                        Text("Stars come from where each \(subjectNoun.singular) sits among the others, and are recalculated every time this opens. They are never written to a \(subjectNoun.singular)'s own rating.")
                    }
                }

                if !settling.isEmpty {
                    Section {
                        ForEach(settling) { standing in
                            row(standing, position: nil)
                        }
                    } header: {
                        Text("Still settling")
                    } footer: {
                        Text("Fewer than \(PreferenceScore.confidenceThreshold) comparisons so far. These have a score, but not enough of one to place or to earn a star.")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }

    /// Everything on screen, in the order it is shown.
    private var shownOrder: [Standing] { ranked + settling }

    @ViewBuilder
    private func row(_ standing: Standing, position: Int?) -> some View {
        if let onReveal {
            Button { onReveal(standing, shownOrder) } label: {
                rowBody(standing, position: position).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            rowBody(standing, position: position)
        }
    }

    private func rowBody(_ standing: Standing, position: Int?) -> some View {
        HStack(spacing: 12) {
            // ⚠️ No position for a settling contender. A number beside a
            // three-comparison score is a claim the data cannot support.
            Text(position.map(String.init) ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(position == nil ? .tertiary : .secondary)
                .frame(width: 28, alignment: .trailing)

            picture(standing)

            VStack(alignment: .leading, spacing: 2) {
                Text(standing.name).font(.body).lineLimit(1)
                Text(standing.comparisons == 1
                     ? "1 comparison" : "\(standing.comparisons) comparisons")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let stars = standing.stars {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= stars ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundStyle(i <= stars ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                }
            }
        }
    }

    /// ⚠️ A video's still keeps its 16:9 shape rather than being squared off
    /// like a portrait. A cropped frame is much harder to recognise, and
    /// recognition is the only thing this picture is for.
    @ViewBuilder
    private func picture(_ standing: Standing) -> some View {
        switch standing.kind {
        case .actor(let profile):
            ProfileImageView(libraryURL: standing.libraryURL,
                             entityId: standing.id,
                             photoUrl: profile.photoUrl) { image in
                Color.clear.overlay(image.resizable().scaledToFill(), alignment: .top)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .video(let asset):
            VideoThumbnailView(asset: asset, libraryURL: standing.libraryURL)
                .frame(width: 72, height: 41)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func load() {
        let entries: [(id: String, name: String, kind: Standing.Kind, owner: URL?)]
        switch contenders {
        case .actors(let profiles):
            entries = profiles.actors.map {
                ($0.id, $0.name, .actor($0),
                 LibrarySession.shared.url(forProfile: $0.id) ?? libraryURL)
            }
        case .videos(let assets):
            entries = assets.map {
                ($0.id.uuidString, ActorKnownFor.displayTitle($0), .video($0),
                 LibrarySession.shared.url(for: $0.id) ?? libraryURL)
            }
        }

        let owners = Dictionary(entries.map { ($0.id, $0.owner) }) { first, _ in first }
        let records = PreferenceStandings.load(ids: entries.map(\.id),
                                               subject: contenders.subject,
                                               owner: { owners[$0] ?? nil },
                                               fallback: libraryURL)

        // ⭐ Retired contenders are excluded entirely. "Neither" means they do
        // not belong in the ranking, and a ranking that still lists them has
        // not honoured the answer.
        let played = records.filter { !$0.value.retired }
        let scores = played.mapValues(\.preferenceScore)
        let stars = PreferenceScoring.derivedStars(scores)

        let byId = Dictionary(entries.map { ($0.id, $0) }) { first, _ in first }
        func standing(_ id: String, _ record: PreferenceRecord) -> Standing? {
            guard let entry = byId[id] else { return nil }
            return Standing(id: id, name: entry.name, kind: entry.kind,
                            libraryURL: entry.owner,
                            comparisons: record.comparisons,
                            stars: stars[id])
        }

        let all = played.compactMap { standing($0.key, $0.value) }
        let byScore: (Standing, Standing) -> Bool = { a, b in
            let sa = scores[a.id]?.value ?? 0, sb = scores[b.id]?.value ?? 0
            return sa == sb ? a.name.localizedStandardCompare(b.name) == .orderedAscending : sa > sb
        }
        ranked = all.filter { $0.stars != nil }.sorted(by: byScore)
        settling = all.filter { $0.stars == nil }.sorted(by: byScore)
        isLoading = false
    }
}
