import Foundation
import GRDB

public struct EntityProfile: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public let id: String
    public var bio: String?
    public var photoUrl: String?
    public var homePage: String?
    
    // NEW FIELDS
    public var gender: String?
    public var hairColor: String?
    public var birthYear: Int?
    public var countryOfOrigin: String?
    
    public var tags: [String]
    public var galleryUrls: [String]
    
    public static let databaseTableName = "entity_profiles"
    
    public init(id: String, bio: String? = nil, photoUrl: String? = nil, homePage: String? = nil, gender: String? = nil, hairColor: String? = nil, birthYear: Int? = nil, countryOfOrigin: String? = nil, tags: [String] = [], galleryUrls: [String] = []) {
        self.id = id
        self.bio = bio
        self.photoUrl = photoUrl
        self.homePage = homePage
        self.gender = gender
        self.hairColor = hairColor
        self.birthYear = birthYear
        self.countryOfOrigin = countryOfOrigin
        self.tags = tags
        self.galleryUrls = galleryUrls
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case bio
        case photoUrl = "photo_url"
        case homePage = "home_page"
        case gender
        case hairColor = "hair_color"
        case birthYear = "birth_year"
        case countryOfOrigin = "country_of_origin"
        case tags
        case galleryUrls = "gallery_urls"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.bio = try container.decodeIfPresent(String.self, forKey: .bio)
        self.photoUrl = try container.decodeIfPresent(String.self, forKey: .photoUrl)
        self.homePage = try container.decodeIfPresent(String.self, forKey: .homePage)
        self.gender = try container.decodeIfPresent(String.self, forKey: .gender)
        self.hairColor = try container.decodeIfPresent(String.self, forKey: .hairColor)
        self.birthYear = try container.decodeIfPresent(Int.self, forKey: .birthYear)
        self.countryOfOrigin = try container.decodeIfPresent(String.self, forKey: .countryOfOrigin)
        
        var decodedTags: [String] = []
        if let tagsArray = try? container.decode([String].self, forKey: .tags) {
            decodedTags = tagsArray
        } else if let tagsString = try? container.decode(String.self, forKey: .tags),
                  let data = tagsString.data(using: .utf8) {
            decodedTags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        self.tags = decodedTags.map { TagNormalizer.normalize(fullTag: $0) }
        
        var decodedGallery: [String] = []
        if let galleryArray = try? container.decode([String].self, forKey: .galleryUrls) {
            decodedGallery = galleryArray
        } else if let galleryString = try? container.decode(String.self, forKey: .galleryUrls),
                  let data = galleryString.data(using: .utf8) {
            decodedGallery = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        self.galleryUrls = decodedGallery
    }
}

// MARK: - GRDB Persistence
extension EntityProfile {
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["bio"] = bio
        container["photo_url"] = photoUrl
        container["home_page"] = homePage
        container["gender"] = gender
        container["hair_color"] = hairColor
        container["birth_year"] = birthYear
        container["country_of_origin"] = countryOfOrigin
        
        if let data = try? JSONEncoder().encode(tags),
           let string = String(data: data, encoding: .utf8) {
            container["tags"] = string
        } else {
            container["tags"] = "[]"
        }
        
        if let data = try? JSONEncoder().encode(galleryUrls),
           let string = String(data: data, encoding: .utf8) {
            container["gallery_urls"] = string
        } else {
            container["gallery_urls"] = "[]"
        }
    }
}
