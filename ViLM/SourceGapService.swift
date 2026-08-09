// SourceGapService.swift
// What else is this performer in? — asking the source (#41, #42, #43).
//
// 🚨 READ-ONLY, and #43 is the whole reason this file is small. It asks the
// provider a question, reads two things from the library, and returns a value.
// It holds no store handle it could write through and calls nothing that
// writes. That property is easy to keep now and very hard to recover once one
// convenience write has been added.
//
// ⚠️ On demand only. Never on a schedule, never on opening a profile — the
// no-background-network posture, and a profile page that fires a request every
// time it is viewed is a rate-limit problem wearing a convenience's clothes.

import Foundation
import LibraryCore

enum SourceGapService {

    /// How many scenes to ask the source for.
    ///
    /// ⚠️ Whatever this is, a prolific performer will exceed it, and a
    /// truncated answer UNDER-reports — which reads as good news. The report
    /// carries `sourceTruncated` so the UI can say so rather than presenting a
    /// capped list as a complete one.
    static let sceneLimit = 100

    enum Failure: LocalizedError {
        case noProvider
        case notIdentified(String)

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "No metadata source is installed, so there is nothing to ask."
            case .notIdentified(let name):
                // ⚠️ Says what to do. "Cannot look up" alone reads as a defect.
                return "\(name) has not been matched to a source yet, so there is no "
                    + "filmography to compare against. Match them first."
            }
        }
    }

    /// The gap for one performer.
    static func report(for profile: EntityProfile,
                       provider: any ActorMetadataProvider,
                       libraryURL: URL) async throws -> SourceGapReport {
        guard let actorSourceId = profile.enrichmentSourceId, !actorSourceId.isEmpty,
              let source = profile.enrichmentSource, !source.isEmpty else {
            throw Failure.notIdentified(profile.name)
        }

        let works = try await provider.knownWorks(actorId: actorSourceId, limit: sceneLimit)

        // ⚠️ Read AFTER the network call, so a long sweep does not compare
        // fresh source data against a library snapshot taken minutes ago.
        let store = try LibraryStore(at: libraryURL)
        let matches = try store.videoMatches(source: source)
        let footprint = try store.videoIdentityFootprint(forActor: profile.name, source: source)

        return SourceGapAudit.report(
            sourceScenes: works.map {
                SourceGap(sourceId: $0.id, title: $0.title,
                          studioName: $0.studioName, releaseDate: $0.releaseDate)
            },
            source: source,
            localMatches: matches,
            localVideos: footprint.total,
            identifiedLocalVideos: footprint.identified,
            // ⭐ A full page back is the signal there may be more. The provider
            // does not report truncation, and inferring it is better than
            // silently presenting a capped list as complete.
            truncated: works.count >= sceneLimit)
    }

    // MARK: - Choosing who to sweep

    enum SweepBasis: Equatable {
        /// The ranking has settled contenders to draw a top tier from.
        case topTier
        /// ⚠️ It has not, so the fifty are arbitrary. The operator's decision,
        /// and the right one: while the ladder is young every performer is
        /// equally likely to be interesting, so an arbitrary fifty is exactly
        /// as informative as any other fifty and costs the same requests.
        case random
    }

    /// How many settled contenders before a "top tier" means anything.
    ///
    /// ⚠️ Not 1. A tier drawn from three settled contenders is a list of three
    /// people, and calling it a ranking would invite the operator to read it as
    /// one.
    static let topTierNeeds = 20

    /// The performers to ask about, and on what basis.
    ///
    /// ⭐ Both modes are returned with their basis so the UI can SAY which it
    /// used. An early sweep presented without that reads as a ranked
    /// recommendation and gets judged as one.
    static func selectSweep(from profiles: [EntityProfile],
                            standings: [String: PreferenceRecord],
                            limit: Int = 50,
                            using generator: inout some RandomNumberGenerator)
    -> (basis: SweepBasis, profiles: [EntityProfile]) {

        // Only performers the source can be asked about at all.
        let askable = profiles.filter {
            !($0.enrichmentSourceId ?? "").isEmpty && !($0.enrichmentSource ?? "").isEmpty
        }

        let settled = askable.filter { profile in
            guard let record = standings[profile.id], !record.retired else { return false }
            return !record.preferenceScore.isProvisional
        }

        if settled.count >= topTierNeeds {
            let ranked = settled.sorted {
                (standings[$0.id]?.score ?? 0) > (standings[$1.id]?.score ?? 0)
            }
            return (.topTier, Array(ranked.prefix(limit)))
        }

        // ⚠️ Retired performers stay out even here. "Neither" was an answer
        // about them, and asking the source about someone removed from the
        // ranking spends a request on a question already settled.
        let eligible = askable.filter { !(standings[$0.id]?.retired ?? false) }
        return (.random, Array(eligible.shuffled(using: &generator).prefix(limit)))
    }
}
