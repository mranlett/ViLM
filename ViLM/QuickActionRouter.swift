// QuickActionRouter.swift
// The single bridge from a Home Screen quick-action tap (delivered via the
// UIKit scene delegate) into SwiftUI. The scene delegate writes `pending`;
// ContentView observes it and performs the action once the library is loaded.
// A shared singleton so the scene delegate (which SwiftUI doesn't hand us
// directly) has somewhere to publish to.

import Foundation
import Combine
import LibraryCore

final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()
    @Published var pending: QuickAction? {
        didSet { pendingSince = pending == nil ? nil : Date() }
    }
    /// When `pending` was set — lets ContentView expire a stale tap instead
    /// of firing it minutes later against whatever library opens next
    /// (DEFECT_INVENTORY M6).
    private(set) var pendingSince: Date?
    private init() {}
}

// Cross-platform display strings for the in-app Dashboard "Shuffle" menu (the
// Home Screen shortcut labels live in QuickActionShortcuts.swift, iOS-only).
extension QuickAction {
    var menuTitle: String {
        switch self {
        case .discoverMix:      return "Discover Mix"
        case .actorSpotlight:   return "Actor Spotlight"
        case .rediscover:       return "Rediscover"
        case .playSomethingNew: return "Play Something New"
        }
    }

    var menuIcon: String {
        switch self {
        case .discoverMix:      return "sparkles"
        case .actorSpotlight:   return "person.crop.circle"
        case .rediscover:       return "clock.arrow.circlepath"
        case .playSomethingNew: return "play.circle"
        }
    }
}
