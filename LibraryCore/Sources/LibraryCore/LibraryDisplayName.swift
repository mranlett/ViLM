// LibraryDisplayName.swift
// Human names for the multi-library session's open libraries. Folder names
// alone are ambiguous — ~/Downloads/Videos and /Volumes/PortableSSD/Downloads/
// Videos are both just "Videos"; the volume/route is often the only meaningful
// differentiator. So libraries are always identified by PATH: a prettified
// full path for sidebar rows and tooltips, and a shortest-UNIQUE-suffix label
// (the editor-tab-title algorithm) for compact chips.

import Foundation

public enum LibraryDisplayName {
    public struct Labels: Sendable, Equatable {
        /// Compact chip label — the shortest path suffix unique within the
        /// open set ("Videos", or "PortableSSD/…/Videos" when names collide).
        public let short: String
        /// Prettified full path ("~/Downloads/Videos", "PortableSSD/Downloads/Videos").
        public let full: String
    }

    /// Labels for the currently open libraries. Uniqueness of `short` is
    /// guaranteed within `urls` (identical full paths excepted, which the
    /// session already forbids). `homeDirectory` is injectable for tests.
    public static func labels(
        for urls: [URL], homeDirectory: String = NSHomeDirectory()
    ) -> [URL: Labels] {
        let componentLists = urls.map { prettyComponents(of: $0, homeDirectory: homeDirectory) }

        // Grow each label's suffix until it collides with no other library's
        // label of the same round. Bounded by the longest component list.
        var suffixLengths = Array(repeating: 1, count: urls.count)
        var changed = true
        while changed {
            changed = false
            let labels = zip(componentLists, suffixLengths).map { suffix(of: $0, length: $1) }
            for i in labels.indices {
                let collides = labels.indices.contains {
                    $0 != i && labels[$0] == labels[i]
                }
                if collides, suffixLengths[i] < componentLists[i].count {
                    suffixLengths[i] += 1
                    changed = true
                }
            }
        }

        var result: [URL: Labels] = [:]
        for (index, url) in urls.enumerated() {
            let components = componentLists[index]
            result[url] = Labels(
                short: shortLabel(components: components, suffixLength: suffixLengths[index]),
                full: components.joined(separator: "/"))
        }
        return result
    }

    /// Path components with the home directory folded to "~" and
    /// "/Volumes/<name>" folded to the volume name. iOS picker URLs with
    /// opaque provider paths simply fall through to their raw components —
    /// the suffix walk still guarantees unique labels.
    static func prettyComponents(of url: URL, homeDirectory: String) -> [String] {
        let path = url.standardizedFileURL.path
        if path == homeDirectory { return ["~"] }
        if path.hasPrefix(homeDirectory + "/") {
            return ["~"] + path.dropFirst(homeDirectory.count + 1).split(separator: "/").map(String.init)
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" {
            return Array(parts.dropFirst())
        }
        return parts
    }

    private static func suffix(of components: [String], length: Int) -> [String] {
        Array(components.suffix(length))
    }

    /// "Videos" (suffix 1), "Downloads/Videos" (suffix 2), and
    /// "PortableSSD/…/Videos" once the differentiator is further up.
    private static func shortLabel(components: [String], suffixLength: Int) -> String {
        let suffixParts = Array(components.suffix(suffixLength))
        guard suffixParts.count > 2 else { return suffixParts.joined(separator: "/") }
        return "\(suffixParts.first!)/…/\(suffixParts.last!)"
    }
}
