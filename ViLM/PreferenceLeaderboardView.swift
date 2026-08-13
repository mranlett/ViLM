// PreferenceLeaderboardView.swift
// Head to Head — the standings (#35).
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

import SwiftUI
import LibraryCore

struct PreferenceLeaderboardView: View {
    let entityProfiles: EntityProfileIndex
    let libraryURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var ranked: [Standing] = []
    @State private var settling: [Standing] = []
    @State private var isLoading = true

    struct Standing: Identifiable {
        let id: String
        let name: String
        let profile: EntityProfile
        let libraryURL: URL?
        let comparisons: Int
        /// Nil while provisional — D8. Absent rather than low, because "not yet
        /// known" and "known to be poor" are different claims.
        let stars: Int?
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
                        Text("Stars come from where each performer sits among the others, and are recalculated every time this opens. They are never written to a performer's own rating.")
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

    private func row(_ standing: Standing, position: Int?) -> some View {
        HStack(spacing: 12) {
            // ⚠️ No position for a settling contender. A number beside a
            // three-comparison score is a claim the data cannot support.
            Text(position.map(String.init) ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(position == nil ? .tertiary : .secondary)
                .frame(width: 28, alignment: .trailing)

            ProfileImageView(libraryURL: standing.libraryURL,
                             entityId: standing.id,
                             photoUrl: standing.profile.photoUrl) { image in
                Color.clear.overlay(image.resizable().scaledToFill(), alignment: .top)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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

    private func load() {
        let contenders = entityProfiles.actors
        let records = PreferenceStandings.load(for: contenders, subject: .actor,
                                               fallback: libraryURL)

        // ⭐ Retired contenders are excluded entirely. "Neither" means they do
        // not belong in the ranking, and a ranking that still lists them has
        // not honoured the answer.
        let played = records.filter { !$0.value.retired }
        let scores = played.mapValues(\.preferenceScore)
        let stars = PreferenceScoring.derivedStars(scores)

        let byId = Dictionary(contenders.map { ($0.id, $0) }) { first, _ in first }
        func standing(_ id: String, _ record: PreferenceRecord) -> Standing? {
            guard let profile = byId[id] else { return nil }
            return Standing(id: id, name: profile.name, profile: profile,
                            libraryURL: LibrarySession.shared.url(forProfile: id) ?? libraryURL,
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
