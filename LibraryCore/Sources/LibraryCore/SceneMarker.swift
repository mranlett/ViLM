import Foundation
import GRDB

/// A named, jumpable timestamp within a video (e.g. "Lightsaber Fight" at
/// 5:25). Removed automatically when its video is deleted via the
/// `scene_markers.asset_id` foreign key's `ON DELETE CASCADE`.
public struct SceneMarker: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public let id: UUID
    public var assetId: UUID
    public var timestampSeconds: Double
    public var label: String?
    public let createdAt: Date

    public static let databaseTableName = "scene_markers"

    public init(id: UUID = UUID(), assetId: UUID, timestampSeconds: Double, label: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.assetId = assetId
        self.timestampSeconds = timestampSeconds
        self.label = label
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case assetId = "asset_id"
        case timestampSeconds = "timestamp_seconds"
        case label
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idString = try container.decode(String.self, forKey: .id)
        self.id = UUID(uuidString: idString) ?? UUID()
        let assetIdString = try container.decode(String.self, forKey: .assetId)
        self.assetId = UUID(uuidString: assetIdString) ?? UUID()
        self.timestampSeconds = try container.decode(Double.self, forKey: .timestampSeconds)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["asset_id"] = assetId.uuidString
        container["timestamp_seconds"] = timestampSeconds
        container["label"] = label
        container["created_at"] = createdAt
    }

    /// A short "MM:SS" (or "H:MM:SS" for long videos) timestamp for display.
    public var formattedTimestamp: String {
        let total = Int(timestampSeconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// What to show as the marker's title: the label if set, else the timestamp.
    public var displayTitle: String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return formattedTimestamp
    }
}
