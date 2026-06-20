import Foundation
import GRDB

public struct Asset: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public let id: UUID
    public var relativePath: String
    public var fileName: String
    public var status: ReviewStatus
    public let createdAt: Date
    public var tags: [String]
    public var externalLink: String?
    public var notes: String?
    public var rating: Int?
    
    public static let databaseTableName = "assets"

    public enum ReviewStatus: String, Codable {
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
                rating: Int? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.fileName = fileName
        self.status = status
        self.createdAt = createdAt
        self.tags = tags.map { TagNormalizer.normalize(fullTag: $0) }
        self.externalLink = externalLink
        self.notes = notes
        self.rating = rating
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

    /// Computes the suggested filename format based on applied tags
    public var suggestedFileNameFromTags: String? {
        let actorsPart = actors.joined(separator: ", ")
        let actionsPart = actions.joined(separator: ", ")
        let studiosPart = studios.joined(separator: ", ")
        
        var components: [String] = []
        if !actorsPart.isEmpty { components.append(actorsPart) }
        if !actionsPart.isEmpty { components.append(actionsPart) }
        if !studiosPart.isEmpty { components.append(studiosPart) }
        
        if components.isEmpty { return nil }
        
        let baseName = components.joined(separator: " - ")
        let ext = (fileName as NSString).pathExtension
        if ext.isEmpty {
            return baseName
        } else {
            return "\(baseName).\(ext)"
        }
    }
}
