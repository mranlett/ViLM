// Asset.swift
// The core video record: file identity, review status, rating, notes,
// prefixed tag list (actor:/tag:/studio:), structured series fields, play
// tracking, and the metadata-driven suggested filename.

import Foundation
import GRDB

public struct Asset: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public let id: UUID
    public var relativePath: String
    public var fileName: String
    public var status: ReviewStatus
    public let createdAt: Date
    public var tags: [String]
    public var externalLink: String?
    public var notes: String?
    public var rating: Int?
    public var videoName: String?          // Series Name
    public var seasonNumber: Int?          // Season / Movie number (Star Wars 3, MWC Season 4)
    public var episodeNumber: Int?         // Episode number
    public var episode: String?            // Episode Title (freeform, e.g. "Valentine's Day")
    /// When the work was published, as `yyyy-MM-dd`.
    ///
    /// Stored verbatim rather than as a Date: sources state a calendar day with
    /// no timezone, and parsing it into an instant invents a precision that was
    /// never there — the same string then displays as a different day depending
    /// on where the reader is.
    public var releaseDate: String?

    // Lookup state (v22). The mirror of the actor fields: the same question is
    // worth asking of a video, and the same answer — "I looked, it isn't
    // there" — has to be recordable so it can leave the queue.
    public var enrichmentState: EnrichmentState?
    public var enrichmentSource: String?

    /// The source's own id for the matched record (v24).
    ///
    /// The mirror of `EntityProfile.enrichmentSourceId`, and it exists for the
    /// same reason: without it a validated match is thrown away, and every
    /// later lookup re-searches by name and re-guesses which record was meant.
    /// A stored id means later lookups FETCH BY ID — a re-search after a
    /// confirmed match is a defect, not a refresh.
    public var enrichmentSourceId: String?

    /// A human-openable link to the matched record, supplied by the provider.
    ///
    /// Separate from the id because core cannot build one from the other: that
    /// would require core to know the source's address, and core never names a
    /// source. A provider supplies both or neither — an id with no link leaves
    /// the operator an opaque string and no way to check a match before
    /// undoing it.
    public var enrichmentUrl: String?

    public var enrichmentCheckedAt: Date?
    public var playCount: Int              // Number of distinct viewing sessions
    public var lastPlayedAt: Date?         // When the video was last played

    public static let databaseTableName = "assets"

    public enum ReviewStatus: String, Codable, Sendable {
        case unreviewed
        case reviewed
    }
    
    public init(id: UUID = UUID(),
                relativePath: String,
                fileName: String,
                status: ReviewStatus = .unreviewed,
                createdAt: Date = Date(),
                tags: [String] = [],
                externalLink: String? = nil,
                notes: String? = nil,
                rating: Int? = nil,
                videoName: String? = nil,
                seasonNumber: Int? = nil,
                episodeNumber: Int? = nil,
                episode: String? = nil,
                releaseDate: String? = nil,
                enrichmentState: EnrichmentState? = nil,
                enrichmentSource: String? = nil,
                enrichmentSourceId: String? = nil,
                enrichmentUrl: String? = nil,
                enrichmentCheckedAt: Date? = nil,
                playCount: Int = 0,
                lastPlayedAt: Date? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.fileName = fileName
        self.status = status
        self.createdAt = createdAt
        // ⚠️ Still normalizes, unlike `init(from:)` above, and the asymmetry is
        // deliberate: this builds a NEW asset from freshly parsed text, where
        // converging sloppy capitalization is the point. Decoding reads back
        // something already stored, where the spelling is an existing answer
        // and re-casing it overrules whoever chose it.
        self.tags = tags.map { TagNormalizer.normalize(fullTag: $0) }
        self.externalLink = externalLink
        self.notes = notes
        self.rating = rating
        self.videoName = videoName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episode = episode
        self.releaseDate = releaseDate
        self.enrichmentState = enrichmentState
        self.enrichmentSource = enrichmentSource
        self.enrichmentSourceId = enrichmentSourceId
        self.enrichmentUrl = enrichmentUrl
        self.enrichmentCheckedAt = enrichmentCheckedAt
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Handle ID
        let idString = try container.decode(String.self, forKey: .id)
        self.id = UUID(uuidString: idString) ?? UUID()
        
        self.relativePath = try container.decode(String.self, forKey: .relativePath)
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.status = try container.decode(ReviewStatus.self, forKey: .status)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.externalLink = try container.decodeIfPresent(String.self, forKey: .externalLink)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        self.videoName = try container.decodeIfPresent(String.self, forKey: .videoName)
        self.seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        self.episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
        self.episode = try container.decodeIfPresent(String.self, forKey: .episode)
        self.releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        self.enrichmentState = try container.decodeIfPresent(EnrichmentState.self, forKey: .enrichmentState)
        self.enrichmentSource = try container.decodeIfPresent(String.self, forKey: .enrichmentSource)
        self.enrichmentSourceId = try container.decodeIfPresent(String.self, forKey: .enrichmentSourceId)
        self.enrichmentUrl = try container.decodeIfPresent(String.self, forKey: .enrichmentUrl)
        self.enrichmentCheckedAt = try container.decodeIfPresent(Date.self, forKey: .enrichmentCheckedAt)
        self.playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        self.lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        
        // Enhanced tag decoding
        var decodedTags: [String] = []
        if let tagsArray = try? container.decode([String].self, forKey: .tags) {
            decodedTags = tagsArray
        } else if let tagsString = try? container.decode(String.self, forKey: .tags),
                  let data = tagsString.data(using: .utf8) {
            // Attempt to decode JSON string from SQLite text column
            decodedTags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        // 🚨 Whitespace only. This used to re-capitalize every tag on DECODE,
        // which meant the spelling stored in the database was not the spelling
        // the app read back: an operator repairing `Point Of View` to
        // `Point of View` had the change undone by the very next read, and a
        // read-modify-write silently rewrote tags nobody had touched.
        //
        // Identity is not case — `TagNormalizer.identityKey` folds it, the
        // filters compare case-insensitively, and the `tags` vocabulary owns
        // the spelling to display. Nothing needed this normalization to tell
        // two spellings apart; it only overruled the operator.
        self.tags = decodedTags.map { TagNormalizer.tidied(fullTag: $0) }
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case relativePath = "relative_path"
        case fileName = "file_name"
        case status
        case createdAt = "created_at"
        case tags
        case externalLink = "external_link"
        case notes
        case rating
        case videoName = "video_name"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case episode
        case releaseDate = "release_date"
        case enrichmentState = "enrichment_state"
        case enrichmentSource = "enrichment_source"
        case enrichmentSourceId = "enrichment_source_id"
        case enrichmentUrl = "enrichment_url"
        case enrichmentCheckedAt = "enrichment_checked_at"
        case playCount = "play_count"
        case lastPlayedAt = "last_played_at"
    }
}

// MARK: - GRDB Persistence
extension Asset {
    /// ⚠️ EVERY stored property must appear here.
    ///
    /// GRDB builds its UPDATE from exactly the keys set on this container, so a
    /// column omitted below is never written by any update — silently, with no
    /// error and no failing test unless one asserts the round-trip. Four
    /// columns were missing here (`release_date` and the three enrichment
    /// fields), which meant every accepted video match was discarded at save
    /// and `VideoBatchPolicy.skipReason` could never skip anything.
    ///
    /// `AssetPreservationTests.testFieldCountIsPinned` fails when a property is
    /// added; adding it here is part of what that guard is asking for.
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["relative_path"] = relativePath
        container["file_name"] = fileName
        container["status"] = status.rawValue
        container["created_at"] = createdAt
        container["external_link"] = externalLink
        container["notes"] = notes
        container["rating"] = rating
        container["video_name"] = videoName
        container["season_number"] = seasonNumber
        container["episode_number"] = episodeNumber
        container["episode"] = episode
        container["release_date"] = releaseDate
        container["enrichment_state"] = enrichmentState?.rawValue
        container["enrichment_source"] = enrichmentSource
        container["enrichment_source_id"] = enrichmentSourceId
        container["enrichment_url"] = enrichmentUrl
        container["enrichment_checked_at"] = enrichmentCheckedAt
        container["play_count"] = playCount
        container["last_played_at"] = lastPlayedAt

        // Encode tags array to JSON String for SQLite storage
        if let jsonData = try? JSONEncoder().encode(tags),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            container["tags"] = jsonString
        } else {
            container["tags"] = "[]"
        }
    }
}

// MARK: - Display Helpers
extension Asset {
    /// Returns only the tags that start with "actor:" (removing the prefix for display)
    public var actors: [String] {
        tags.filter { $0.hasPrefix("actor:") }
            .map { String($0.dropFirst(6)) }
            .sorted()
    }

    /// Returns only the tags that start with "tag:" (removing the prefix for display)
    public var actions: [String] {
        tags.filter { $0.hasPrefix("tag:") }
            .map { String($0.dropFirst(4)) }
            .sorted()
    }

    /// Returns only the tags that start with "studio:" (removing the prefix for display)
    public var studios: [String] {
        tags.filter { $0.hasPrefix("studio:") }
            .map { String($0.dropFirst(7)) }
            .sorted()
    }

    /// The human-readable series/episode block used in display and filenames:
    /// Series Name, a bare Season/Movie number, "Episode N", and the episode
    /// title — joined by spaces, skipping any field that is empty.
    public var seriesTitleBlock: String {
        var parts: [String] = []
        if let v = videoName, !v.isEmpty { parts.append(v) }
        if let s = seasonNumber { parts.append("\(s)") }
        if let e = episodeNumber { parts.append("Episode \(e)") }
        if let t = episode?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
        return parts.joined(separator: " ")
    }

    public var suggestedFileNameFromTags: String? {
        let actorsPart = actors.joined(separator: ", ")
        let tagsPart = actions.joined(separator: ", ")
        let studiosPart = studios.joined(separator: ", ")

        let videoPart = seriesTitleBlock

        // Section priority (kept when the name must be shortened):
        // 1: Actors  2: Series/Episode block  3: Tags  4: Studios
        var components = [actorsPart, videoPart, tagsPart, studiosPart].filter { !$0.isEmpty }
        if components.isEmpty { return nil }
        
        var baseName = components.joined(separator: " - ")
        
        let ext = (fileName as NSString).pathExtension
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"
        let maxBaseLength = 250 - extSuffix.count
        
        if baseName.count <= maxBaseLength {
            return baseName + extSuffix
        }
        
        // Too long. Start dropping from lowest priority (right to left)
        if !studiosPart.isEmpty {
            components.removeAll { $0 == studiosPart }
            baseName = components.joined(separator: " - ")
            if baseName.count <= maxBaseLength { return baseName + extSuffix }
        }
        
        if !tagsPart.isEmpty {
            components.removeAll { $0 == tagsPart }
            baseName = components.joined(separator: " - ")
            if baseName.count <= maxBaseLength { return baseName + extSuffix }
        }
        
        if !videoPart.isEmpty {
            components.removeAll { $0 == videoPart }
            baseName = components.joined(separator: " - ")
            if baseName.count <= maxBaseLength { return baseName + extSuffix }
        }
        
        // If STILL too long (e.g. huge actor list), safely truncate the actors
        if baseName.count > maxBaseLength {
            baseName = String(baseName.prefix(maxBaseLength))
        }
        
        return baseName + extSuffix
    }
}
