// ProfileThumbnailStore.swift
// Generates and resolves the grid-sized derivatives of profile photos (#84).
//
// The naming and freshness rules live in `LibraryCore.ProfileThumbnailNaming`
// where they are unit-tested. This file is the part that needs CoreGraphics and
// a filesystem: producing a physically smaller JPEG, once, so that grid cells
// stop decoding 4–5 MB sources to draw themselves.
//
// ⚠️ Read the WHY in ProfileThumbnailNaming before changing the approach. In
// short: downsampling at READ time was already tried (#7) and measured failing,
// because CGImageSourceCreateThumbnailAtIndex still parses the whole JPEG.
// Churn stayed flat at ~20 GiB while retained memory rose 9×. The only thing
// that makes the decode cheap is a smaller file on disk.

import Foundation
import ImageIO
import LibraryCore
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum ProfileThumbnailStore {

    /// Generations already running, so a scroll that materialises the same cell
    /// repeatedly does the work once.
    ///
    /// Mirrors the in-flight guard `ProfileImageView` already uses for
    /// downloads, and for the same reason: without it, a fast scroll fires the
    /// same expensive job per appearance.
    private static let inFlightLock = NSLock()
    nonisolated(unsafe) private static var inFlight: Set<String> = []

    private static func begin(_ key: String) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlight.insert(key).inserted
    }

    private static func end(_ key: String) {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        inFlight.remove(key)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// A derivative that exists AND is at least as new as its source.
    ///
    /// 🚨 Freshness is checked, never assumed. The primary photo's filename is
    /// fixed per entity, so a presence check would serve the old face forever
    /// after a re-star — #21, which cost a spike to diagnose once.
    static func freshDerivativeURL(forSourceFileName sourceFileName: String,
                                   sourceURL: URL,
                                   maxPixelSize: Int = ProfileThumbnailNaming.defaultMaxPixelSize) -> URL? {
        guard let name = ProfileThumbnailNaming.fileName(forSourceFileName: sourceFileName,
                                                        maxPixelSize: maxPixelSize),
              let candidate = LibrarySession.shared.existingProfileThumbnailURL(fileName: name),
              let derivativeModified = modificationDate(of: candidate),
              let sourceModified = modificationDate(of: sourceURL),
              ProfileThumbnailNaming.isFresh(derivativeModified: derivativeModified,
                                             sourceModified: sourceModified)
        else { return nil }
        return candidate
    }

    /// Produce the derivative for a source photo, if it is missing or stale.
    ///
    /// Runs at `.utility`: this is repair work behind an image the user can
    /// already see via the fallback path, so it must not compete with scrolling.
    /// (See QoSConventionTests for the project rule.)
    @discardableResult
    static func generateIfNeeded(sourceFileName: String,
                                 sourceURL: URL,
                                 profileId: String,
                                 maxPixelSize: Int = ProfileThumbnailNaming.defaultMaxPixelSize) async -> URL? {
        guard let name = ProfileThumbnailNaming.fileName(forSourceFileName: sourceFileName,
                                                        maxPixelSize: maxPixelSize),
              let dir = LibrarySession.shared.profileThumbsDir(forProfile: profileId)
        else { return nil }

        if let fresh = freshDerivativeURL(forSourceFileName: sourceFileName,
                                          sourceURL: sourceURL,
                                          maxPixelSize: maxPixelSize) {
            return fresh
        }

        let destination = dir.appendingPathComponent(name)
        guard begin(destination.path) else { return nil }
        defer { end(destination.path) }

        return await Task.detached(priority: .utility) { () -> URL? in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return nil
            }

            guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                return nil
            }

            // ⚠️ Written to a sibling temp path and moved into place. A reader
            // only ever checks that the destination EXISTS, so a half-written
            // file at that path would be found, fail to decode, and look like a
            // corrupt library. The move is atomic within one volume.
            let temp = dir.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
            guard let dest = CGImageDestinationCreateWithURL(temp as CFURL,
                                                             UTType.jpeg.identifier as CFString,
                                                             1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            return destination
        }.value
    }

    /// Discard a derivative that would not decode.
    ///
    /// 🚨 Deletes the DERIVATIVE and never the source. The fallback path in
    /// `ProfileImageView` deletes an undecodable SOURCE so it can be
    /// re-downloaded; applying that reflex here would destroy an original the
    /// library may be the only copy of, to fix a cache.
    static func discardDerivative(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
