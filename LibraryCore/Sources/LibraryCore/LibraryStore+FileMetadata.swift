// LibraryStore+FileMetadata.swift
// Running Stage A against a real library (#9).
//
// ⚠️ The RULES live in `FileMetadataStageA`, where they are testable without a
// disk. This file is only the wiring: what the filesystem says, and where the
// answer is written. Keeping the decision out of here is what made the
// staleness comparison, the missing-file case and the cancellation semantics
// assertable at all.

import Foundation
import AVFoundation

public extension LibraryStore {

    /// Opens one video and reads the four things a display needs.
    ///
    /// ⚠️ Returns nil rather than throwing. An unreadable file is a NORMAL
    /// outcome for this stage — damaged, exotic, or not really video — and
    /// treating it as an error would let one of them stop the run.
    ///
    /// ⭐ `naturalSize` applied through `preferredTransform`, so a portrait
    /// video recorded in landscape with a rotation flag reports the dimensions
    /// it actually displays at. The untransformed size is the common bug here
    /// and it looks right on most files.
    static func mediaFacts(at url: URL) async -> MediaFacts? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }

        let displayed = size.applying(transform)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }

        var codec: String?
        if let descriptions = try? await track.load(.formatDescriptions),
           let first = descriptions.first {
            let type = CMFormatDescriptionGetMediaSubType(first)
            codec = String(bytes: [
                UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
                UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF),
            ], encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        }

        return MediaFacts(duration: seconds,
                          width: Int(abs(displayed.width)),
                          height: Int(abs(displayed.height)),
                          codec: codec)
    }

    /// Populates duration, dimensions and codec (#10, F6 Stage B).
    ///
    /// 🚨 SLOW. This opens every unmeasured file and parses its headers, at a
    /// cost that depends on the codec. It is never run unattended — see the
    /// scan path, which runs Stage A only and says why.
    @discardableResult
    func backfillMediaFacts(libraryURL: URL,
                            isCancelled: @escaping () -> Bool = { false },
                            onProgress: @escaping (StageBSummary) -> Void = { _ in })
        async throws -> StageBSummary {
        let assets = try fetchAllAssets()
        let manager = FileManager.default
        var summary = StageBSummary()

        // ⚠️ Written as a loop rather than through the shared `backfill`
        // because measuring is `async` here and that entry point is not. The
        // RULES are still the shared ones — `isCurrent` decides what needs
        // work, and it is the same function the tests pin.
        for (index, asset) in assets.enumerated() {
            if isCancelled() {
                summary.remaining = assets.count - index
                break
            }
            let url = libraryURL.appendingPathComponent(asset.relativePath)
            let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

            guard !FileMetadataStageB.isCurrent(asset, modifiedOnDisk: modified) else {
                summary.unchanged += 1
                continue
            }
            guard let facts = await LibraryStore.mediaFacts(at: url) else {
                summary.unreadable.append(asset.relativePath)
                continue
            }

            var updated = asset
            updated.duration = facts.duration
            updated.width = facts.width
            updated.height = facts.height
            updated.codec = facts.codec
            try updateAsset(updated)
            summary.measured += 1
            onProgress(summary)
        }

        return summary
    }

    /// Populates size and modified date for everything in this library that
    /// needs it.
    ///
    /// ⭐ No full rescan. It reads the rows it already has and stats each file,
    /// so an existing library is brought up to date without re-walking the
    /// tree or touching anything the operator has recorded.
    ///
    /// - Parameter isCancelled: checked before each file. Whatever has been
    ///   written stays written; the rest keeps falling back to reading the
    ///   file, exactly as before this existed.
    @discardableResult
    func backfillFileMetadata(libraryURL: URL,
                              isCancelled: @escaping () -> Bool = { false },
                              onProgress: (StageASummary) -> Void = { _ in })
        throws -> StageASummary {
        let assets = try fetchAllAssets()
        let manager = FileManager.default

        return try FileMetadataStageA.backfill(
            assets,
            facts: { asset in
                let path = libraryURL.appendingPathComponent(asset.relativePath).path
                guard let attributes = try? manager.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      let modified = attributes[.modificationDate] as? Date
                else { return nil }
                return FileFacts(size: size, modified: modified)
            },
            isCancelled: isCancelled,
            onProgress: onProgress,
            write: { try updateAsset($0) })
    }
}
