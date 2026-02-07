import Foundation
import GRDB

public struct Asset: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public let id: UUID
    public let relativePath: String
    public let fileName: String
    public var status: ReviewStatus
    public let createdAt: Date
    public var tags: [String]
    
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
                tags: [String] = []) {
        self.id = id
        self.relativePath = relativePath
        self.fileName = fileName
        self.status = status
        self.createdAt = createdAt
        self.tags = tags
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
        
        // Enhanced tag decoding
        if let tagsArray = try? container.decode([String].self, forKey: .tags) {
            self.tags = tagsArray
        } else if let tagsString = try? container.decode(String.self, forKey: .tags),
                  let data = tagsString.data(using: .utf8) {
            // Attempt to decode JSON string from SQLite text column
            self.tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            self.tags = []
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case relativePath = "relative_path"
        case fileName = "file_name"
        case status
        case createdAt = "created_at"
        case tags
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
}
