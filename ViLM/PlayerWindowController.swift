import AppKit
import SwiftUI
import AVKit

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    func show(title: String, player: AVPlayer) {
        if let window {
            window.title = title
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = PlayerPopoutView(title: title, player: player)
        let hosting = NSHostingView(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        win.title = title
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
