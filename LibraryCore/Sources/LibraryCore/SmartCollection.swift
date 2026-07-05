import Foundation
import GRDB

public struct SmartCollection: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public let id: String
    public var name: String
    public var filterData: Data
    public var createdAt: Date
    
    public static let databaseTableName = "smart_collections"
    
    public init(id: String = UUID().uuidString, name: String, filterData: Data, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.filterData = filterData
        self.createdAt = createdAt
    }
}
