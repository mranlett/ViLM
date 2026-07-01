import Foundation

enum AppRoute: Hashable {
    case asset(UUID)
    case assets(Set<UUID>)
    case entityProfile(category: String, name: String)
}
