import Foundation
import GRDB

public struct Asset: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    public let id: UUID
    public var relativePath: String
    public var fileName: String
    public var status: ReviewStatus
    public let createdAt: Date
    public var tags: [String]
    public var externalLink: String?
    public var notes: String?
    public var rating: Int?
    public var videoName: String?
    public var episode: String?
    
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
                episode: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.fileName = fileName
        self.status = status
        self.createdAt = createdAt
        self.tags = tags.map { TagNormalizer.normalize(fullTag: $0) }
        self.externalLink = externalLink
        self.notes = notes
        self.rating = rating
        self.videoName = videoName
        self.episode = episode
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
        self.episode = try container.decodeIfPresent(String.self, forKey: .episode)
        
        // Enhanced tag decoding
        var decodedTags: [String] = []
        if let tagsArray = try? container.decode([String].self, forKey: .tags) {
            decodedTags = tagsArray
        } else if let tagsString = try? container.decode(String.self, forKey: .tags),
                  let data = tagsString.data(using: .utf8) {
            // Attempt to decode JSON string from SQLite text column
            decodedTags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        self.tags = decodedTags.map { TagNormalizer.normalize(fullTag: $0) }
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
        case episode
    }
}

// MARK: - GRDB Persistence
extension Asset {
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
        container["episode"] = episode
        
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

    public var suggestedFileNameFromTags: String? {
        let actorsPart = actors.joined(separator: ", ")
        let tagsPart = actions.joined(separator: ", ")
        let studiosPart = studios.joined(separator: ", ")
        
        var videoPartComponents: [String] = []
        if let v = videoName, !v.isEmpty { videoPartComponents.append(v) }
        if let e = episode, !e.isEmpty { videoPartComponents.append(e) }
        let videoPart = videoPartComponents.joined(separator: " ")
        
        // Priority 1: Actors
        // Priority 2: Video Part
        // Priority 3: Tags
        // Priority 4: Studios
        
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
