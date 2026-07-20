// QuickActionShortcuts.swift
// iOS Home Screen quick actions (long-press the app icon). Maps each
// `QuickAction` to a `UIApplicationShortcutItem` and back, and hosts the app +
// scene delegates that register the items and deliver a tap into
// `QuickActionRouter`. This is UIKit's icon-menu mechanism — deliberately NOT
// App Intents (which would surface in Siri/Shortcuts instead).

#if os(iOS)
import UIKit
import LibraryCore

extension QuickAction {
    var shortcutType: String { "com.vilm.quickaction.\(rawValue)" }

    var shortcutTitle: String {
        switch self {
        case .discoverMix:      return "Discover Mix"
        case .actorSpotlight:   return "Actor Spotlight"
        case .rediscover:       return "Rediscover"
        case .playSomethingNew: return "Play Something New"
        }
    }

    var shortcutSubtitle: String? {
        switch self {
        case .discoverMix:      return "A fresh tag pairing"
        case .actorSpotlight:   return "Someone you feature"
        case .rediscover:       return "A favorite you've not seen lately"
        case .playSomethingNew: return "Never watched"
        }
    }

    private var shortcutSymbol: String {
        switch self {
        case .discoverMix:      return "sparkles"
        case .actorSpotlight:   return "person.crop.circle"
        case .rediscover:       return "clock.arrow.circlepath"
        case .playSomethingNew: return "play.circle"
        }
    }

    var shortcutItem: UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: shortcutType,
            localizedTitle: shortcutTitle,
            localizedSubtitle: shortcutSubtitle,
            icon: UIApplicationShortcutIcon(systemImageName: shortcutSymbol),
            userInfo: nil
        )
    }

    init?(shortcutType: String) {
        guard let match = QuickAction.allCases.first(where: { $0.shortcutType == shortcutType }) else { return nil }
        self = match
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The four items are fixed; register them dynamically (no Info.plist,
        // since the project uses GENERATE_INFOPLIST_FILE).
        application.shortcutItems = QuickAction.allCases.map { $0.shortcutItem }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

/// Captures a quick action on cold launch (`willConnectTo`) and while running
/// (`performActionFor`), publishing it to the router for ContentView to act on.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcut = connectionOptions.shortcutItem,
           let action = QuickAction(shortcutType: shortcut.type) {
            QuickActionRouter.shared.pending = action
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if let action = QuickAction(shortcutType: shortcutItem.type) {
            QuickActionRouter.shared.pending = action
            completionHandler(true)
        } else {
            completionHandler(false)
        }
    }
}
#endif
