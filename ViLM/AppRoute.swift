import Foundation

enum AppRoute: Hashable {
    case asset(UUID, context: [UUID])
    case assets(Set<UUID>)
    case entityProfile(category: String, name: String)
    case batchActors(Set<String>)
}
