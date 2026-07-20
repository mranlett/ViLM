//
//  ViLMApp.swift
//  ViLM
//
//  Created by Matt Ranlett on 2/4/26.
//

import SwiftUI

@main
struct ViLMApp: App {
#if os(iOS)
    // Registers Home Screen quick actions and routes taps into QuickActionRouter.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
