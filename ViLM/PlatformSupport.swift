// PlatformSupport.swift
// Cross-platform (iOS/macOS) aliases used throughout the app: PlatformImage
// (UIImage/NSImage), the standard background colors, and an Image initializer
// that accepts either platform's image type.

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
let PlatformSystemBackground = UIColor.systemBackground
let PlatformSystemGroupedBackground = UIColor.systemGroupedBackground
#else
import AppKit
typealias PlatformImage = NSImage
let PlatformSystemBackground = NSColor.windowBackgroundColor
let PlatformSystemGroupedBackground = NSColor.windowBackgroundColor
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
