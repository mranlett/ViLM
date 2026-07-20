// AppRoute.swift
// Navigation destinations for the app's NavigationStacks - one shared route
// enum so compact (iPhone) and split-view (iPad/macOS) layouts push the same
// screens.

import Foundation
import LibraryCore

enum AppRoute: Hashable {
    /// Compact-width hub: shows the section selected in the sidebar
    /// (dashboard, asset grid, actor gallery, or tag gallery).
    case browse
    case asset(UUID, context: [UUID])
    case assets(Set<UUID>)
    case entityProfile(category: String, name: String)
    case batchActors(Set<String>)
    /// A Smart Shelf's full "See All" list, computed live from a `LibraryQuery`.
    case shelf(LibraryQuery)
}
