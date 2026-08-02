// FileResponseCache.swift
// On-disk implementation of PluginResponseCache (D6).
//
// Lives under the library's .catalog directory so a plugin's cached responses
// travel with the library they enriched, and so purging is a directory removal
// rather than a scan.
//
// Layout:  <library>/.catalog/pluginCache/<pluginId>/<sha of requestKey>
//
// The plugin id is a DIRECTORY, which is what makes per-plugin purge cheap and
// total: uninstalling removes the directory, and nothing of that plugin's data
// survives anywhere else.

import Foundation
import CryptoKit

public final class FileResponseCache: PluginResponseCache, @unchecked Sendable {

    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    /// - Parameter libraryURL: the library root; the cache sits inside its
    ///   `.catalog` directory alongside thumbnails and contact sheets.
    public init(libraryURL: URL, fileManager: FileManager = .default) {
        self.root = libraryURL.appendingPathComponent(".catalog/pluginCache", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Directory for one plugin. Ids are hashed rather than used verbatim so an
    /// id containing a path separator cannot escape the cache root.
    private func directory(_ pluginId: String) -> URL {
        root.appendingPathComponent(Self.digest(pluginId), isDirectory: true)
    }

    private func file(_ pluginId: String, _ requestKey: String) -> URL {
        directory(pluginId).appendingPathComponent(Self.digest(requestKey))
    }

    /// Stable, filesystem-safe name for an arbitrary string.
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - PluginResponseCache

    public func data(pluginId: String, requestKey: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: file(pluginId, requestKey))
    }

    public func store(_ data: Data, pluginId: String, requestKey: String) {
        lock.lock(); defer { lock.unlock() }
        let dir = directory(pluginId)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            // Atomic so a crash mid-write cannot leave a truncated response that
            // would later be replayed as if it were complete.
            try data.write(to: file(pluginId, requestKey), options: .atomic)
        } catch {
            // A cache is an optimisation. Failing to write one must never fail
            // the operation that produced the data.
        }
    }

    public func size(pluginId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let dir = directory(pluginId)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    public func purge(pluginId: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory(pluginId))
    }

    public func purgeAll() {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: root)
    }
}
