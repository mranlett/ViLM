import Foundation
import GRDB

public struct EntityProfile: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public let id: String
    public var bio: String?
    public var photoUrl: String?
    public var homePage: String?
    
    public static let databaseTableName = "entity_profiles"
    
    public init(id: String, bio: String? = nil, photoUrl: String? = nil, homePage: String? = nil) {
        self.id = id
        self.bio = bio
        self.photoUrl = photoUrl
        self.homePage = homePage
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case bio
        case photoUrl = "photo_url"
        case homePage = "home_page"
    }
}

// MARK: - GRDB Persistence
extension EntityProfile {
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["bio"] = bio
        container["photo_url"] = photoUrl
        container["home_page"] = homePage
    }
}
