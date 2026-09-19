// VideoEditingService.swift
// Two file-modifying edits: trim (frame-accurate cut via full re-encode) and
// flip (horizontal mirror, pixels baked in so it reads correctly in any player).
// Both work on a copy under `.catalog/editing/`, verify it, then atomically
// replace the original in place (same path/filename) and regenerate the video's
// cached visuals; trim also shifts/drops scene-marker timestamps. The pure
// marker math is unit-tested; the real AVFoundation re-encode is verified
// manually on-device (a valid, decodable video is required — AVFoundation-
// supported formats like .mp4/.mov/.m4v).

import Foundation
import AVFoundation
import CoreGraphics

public enum VideoEditError: Error {
    case sourceMissing
    case exportSetupFailed
    case exportFailed
    case verificationFailed
}

/// What a trim or flip is doing right now, for a UI that wants to show more
/// than a spinner (#98).
///
/// 🚨 The distinction that earns this a type is `preparing` versus
/// `exporting(0)`. Both mean "nothing has happened yet", but only the second is
/// a NUMBER, and a determinate bar drawn from it sits visibly at zero — which
/// reads as stuck rather than as starting. A bare `Double` cannot express the
/// difference, so the view would have to guess at it.
public enum VideoEditProgress: Equatable, Sendable {
    /// The export session has been started and has reported nothing yet.
    case preparing
    /// Fractional completion of the re-encode, 0...1 — the long part.
    case exporting(Double)
    /// The re-encode is done: verifying the copy, swapping it in for the
    /// original, rebasing markers and rebuilding the cached visuals.
    ///
    /// ⚠️ A phase of its own because it is NOT instant — regenerating visuals
    /// and refreshing the duplicate-scan fingerprint take seconds on a long
    /// video. Folded into `exporting(1)` it would leave a full bar sitting
    /// there with nothing to say why.
    case finishing

    /// The value a determinate bar should show, or nil when the UI must keep
    /// showing an indeterminate spinner.
    ///
    /// ⭐ This is #98's "degrade to the spinner rather than a bar stuck at 0%",
    /// expressed ONCE and here, where a test can reach it — rather than as an
    /// `if` in the view, where it cannot.
    public var determinateFraction: Double? {
        switch self {
        case .preparing:        return nil
        case let .exporting(f): return f > 0 ? min(f, 1) : nil
        case .finishing:        return 1
        }
    }
}

/// Called with each change as an edit runs. ⚠️ Not on any particular actor —
/// it is invoked from whichever task is driving the export, so a UI caller
/// hops to the main actor itself.
public typealias VideoEditProgressHandler = @Sendable (VideoEditProgress) -> Void

public struct VideoEditingService {
    public init() {}

    // MARK: - Marker adjustment (pure, tested)

    public struct TrimMarkerAdjustment: Sendable, Equatable {
        public let shifted: [SceneMarker]   // kept markers, timestamps rebased to the new start
        public let dropped: [SceneMarker]   // markers that fell inside the cut-away region
    }

    /// Given a kept range `[keepStart, keepEnd]`, returns the markers that
    /// survive (with timestamps rebased so they still point at the same moment)
    /// and the markers that fall outside it (to be dropped). Bounds inclusive.
    public static func adjustMarkersForTrim(
        _ markers: [SceneMarker], keepStart: Double, keepEnd: Double
    ) -> TrimMarkerAdjustment {
        var shifted: [SceneMarker] = []
        var dropped: [SceneMarker] = []
        for marker in markers {
            let t = marker.timestampSeconds
            if t >= keepStart && t <= keepEnd {
                var m = marker
                m.timestampSeconds = t - keepStart
                shifted.append(m)
            } else {
                dropped.append(marker)
            }
        }
        return TrimMarkerAdjustment(shifted: shifted, dropped: dropped)
    }

    // MARK: - Trim

    /// Keeps only `[keepStart, keepEnd]` of the video (frame-accurate re-encode),
    /// replaces the original in place, and rebases/drops scene markers.
    public func trim(_ asset: Asset, in libraryURL: URL, keepStart: Double, keepEnd: Double,
                     onProgress: VideoEditProgressHandler? = nil) async throws {
        let sourceURL = libraryURL.appendingPathComponent(asset.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw VideoEditError.sourceMissing }

        let avAsset = AVURLAsset(url: sourceURL)
        let range = CMTimeRange(
            start: CMTime(seconds: keepStart, preferredTimescale: 600),
            end: CMTime(seconds: keepEnd, preferredTimescale: 600))
        let working = try await export(avAsset, in: libraryURL, sourceExt: sourceURL.pathExtension,
                                       timeRange: range, videoComposition: nil, onProgress: onProgress)
        try await finalize(working: working, replacing: sourceURL, asset: asset, in: libraryURL,
                           onProgress: onProgress) { store in
            try Self.rebaseMarkers(for: asset, keepStart: keepStart, keepEnd: keepEnd,
                                   store: store, libraryURL: libraryURL)
        }
    }

    /// Rebases an asset's scene markers after a trim: kept markers shift to
    /// the new timeline, cut-away markers are deleted (rows in ONE
    /// transaction — a mid-rebase failure can't leave half the markers
    /// pointing at the wrong moments, DEFECT_INVENTORY H1), and dropped
    /// markers' preview thumbnails are removed from disk. Errors propagate:
    /// the trimmed file is already in place by the time this runs, so the
    /// user must be told the markers may be stale rather than failing silently.
    static func rebaseMarkers(
        for asset: Asset, keepStart: Double, keepEnd: Double,
        store: LibraryStore, libraryURL: URL
    ) throws {
        let markers = try store.fetchSceneMarkers(for: asset.id)
        let adjustment = Self.adjustMarkersForTrim(markers, keepStart: keepStart, keepEnd: keepEnd)
        try store.performInTransaction { db in
            for marker in adjustment.dropped {
                try store.deleteSceneMarker(id: marker.id, in: db)
            }
            for marker in adjustment.shifted {
                try store.saveSceneMarker(marker, in: db) // save == upsert (same id)
            }
        }
        // The dropped markers' preview files must go too, or they linger as
        // orphans on disk (rows are gone; files aren't cascaded). File
        // cleanup stays outside the transaction — it's best-effort by design.
        let sheets = ContactSheetService(store: store)
        for marker in adjustment.dropped {
            sheets.deleteMarkerThumbnail(markerId: marker.id, libraryURL: libraryURL)
        }
    }

    // MARK: - Flip (horizontal mirror)

    /// Mirrors the video left-right (baking the flip into the pixels) so
    /// backwards-rendering text reads correctly everywhere, then replaces the
    /// original in place. Markers are unaffected (timestamps don't change).
    public func flip(_ asset: Asset, in libraryURL: URL,
                     onProgress: VideoEditProgressHandler? = nil) async throws {
        let sourceURL = libraryURL.appendingPathComponent(asset.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw VideoEditError.sourceMissing }

        let avAsset = AVURLAsset(url: sourceURL)
        guard let track = try await avAsset.loadTracks(withMediaType: .video).first else {
            throw VideoEditError.exportSetupFailed
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let duration = try await avAsset.load(.duration)

        // Size as displayed (after the track's own orientation transform).
        let rendered = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(rendered.width), height: abs(rendered.height))

        // Mirror horizontally in render space, composed on top of orientation.
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: renderSize.width, ty: 0)
        let finalTransform = preferredTransform.concatenating(mirror)

        var frameRate = try await track.load(.nominalFrameRate)
        if frameRate <= 0 { frameRate = 30 }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate.rounded())))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let working = try await export(avAsset, in: libraryURL, sourceExt: sourceURL.pathExtension,
                                       timeRange: nil, videoComposition: videoComposition,
                                       onProgress: onProgress)
        try await finalize(working: working, replacing: sourceURL, asset: asset, in: libraryURL,
                           onProgress: onProgress, markerWork: nil)
    }

    // MARK: - Shared export / finalize

    /// How often `AVAssetExportSession.progress` is sampled.
    ///
    /// ⚠️ 10 Hz: often enough that the bar moves continuously on a short clip,
    /// rare enough that a two-hour re-encode is not spent waking up to report a
    /// number that has not changed.
    static let progressPollInterval = Duration.milliseconds(100)

    /// The next fraction to report, given the last one — never smaller.
    ///
    /// 🚨 Pure and `static` so #98's two awkward cases are TESTABLE without an
    /// encoder: `progress` can jitter downwards between samples, and a bar that
    /// retreats reads as a bug in the app rather than as noise in AVFoundation;
    /// and a session that reports nothing usable (NaN before it starts, or a
    /// format that never updates) must leave the fraction where it was rather
    /// than throwing the bar to an arbitrary place.
    static func monotonicFraction(_ sampled: Float, notBelow previous: Double) -> Double {
        let value = Double(sampled)
        guard value.isFinite, value > previous else { return previous }
        return min(value, 1)
    }

    /// Whether an export session has stopped, one way or another.
    ///
    /// ⚠️ `.unknown` is NOT terminal. The session has been started but may not
    /// have transitioned yet, and calling that finished would leave the polling
    /// loop immediately and report a failure before the export began.
    private static func isTerminal(_ status: AVAssetExportSession.Status) -> Bool {
        switch status {
        case .completed, .failed, .cancelled:   return true
        case .unknown, .waiting, .exporting:    return false
        // A status this build does not know is treated as stopped rather than
        // looped on forever — the guard that follows then reports it.
        @unknown default:                       return true
        }
    }

    private func export(
        _ avAsset: AVURLAsset, in libraryURL: URL, sourceExt: String,
        timeRange: CMTimeRange?, videoComposition: AVMutableVideoComposition?,
        onProgress: VideoEditProgressHandler?
    ) async throws -> URL {
        let workingDir = libraryURL.appendingPathComponent(".catalog/editing", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        let ext = sourceExt.lowercased() == "mov" ? "mov" : "mp4"
        let fileType: AVFileType = ext == "mov" ? .mov : .mp4
        let workingURL = workingDir.appendingPathComponent("edit-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: workingURL)

        // Re-encoding preset → frame-accurate (passthrough would snap to keyframes).
        guard let session = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoEditError.exportSetupFailed
        }
        session.outputURL = workingURL
        session.outputFileType = fileType
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }

        // 🚨 Polled from THIS task rather than from a second one watching the
        // session. `AVAssetExportSession` is not Sendable, so a polling `Task`
        // capturing it would not compile under this package's Swift 6 language
        // mode — and no second signal is needed anyway: `status` reaching a
        // terminal value is the same fact the completion handler announces, and
        // is already what the guard below tests.
        onProgress?(.preparing)
        var fraction = 0.0
        session.exportAsynchronously {}
        while !Self.isTerminal(session.status) {
            fraction = Self.monotonicFraction(session.progress, notBelow: fraction)
            onProgress?(.exporting(fraction))
            do {
                try await Task.sleep(for: Self.progressPollInterval)
            } catch {
                // ⚠️ The enclosing task was cancelled. Stop the encode rather
                // than spinning on a sleep that will keep throwing — the status
                // then settles as `.cancelled` and the guard below cleans up
                // the working file, which is what a failed export already does.
                session.cancelExport()
                break
            }
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: workingURL)
            throw VideoEditError.exportFailed
        }
        return workingURL
    }

    private func finalize(
        working: URL, replacing sourceURL: URL, asset: Asset, in libraryURL: URL,
        onProgress: VideoEditProgressHandler?,
        markerWork: ((LibraryStore) throws -> Void)?
    ) async throws {
        // ⭐ Announced here rather than at the end of the export, because this
        // is the work the phase actually names — and it is the slow tail a full
        // bar would otherwise sit through unexplained.
        onProgress?(.finishing)

        // Verify the export is a playable, non-empty video before touching the
        // original — a bad export must never destroy the source.
        let check = AVURLAsset(url: working)
        let playable = (try? await check.load(.isPlayable)) ?? false
        let seconds = (try? await check.load(.duration).seconds) ?? 0
        guard playable, seconds > 0 else {
            try? FileManager.default.removeItem(at: working)
            throw VideoEditError.verificationFailed
        }

        // Atomically swap the edited copy in for the original (same path).
        _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: working)

        // Apply marker changes, then rebuild the video's cached visuals.
        // A marker failure propagates (the UI must report it — the file swap
        // has already happened and can't be undone), but the visual rebuild
        // and cleanup below still matter either way, hence no early exit
        // structure: the throw happens after nothing else remains.
        let store = try LibraryStore(at: libraryURL)
        var markerError: Error?
        do { try markerWork?(store) } catch { markerError = error }
        await ContactSheetService(store: store).regenerateAllVisuals(for: asset, libraryURL: libraryURL)

        // The file's bytes changed, so its duplicate-scan fingerprint is
        // stale — refresh it now (a few seconds on top of a re-encode)
        // rather than leaving the invalidated entry for the next scan.
        await Self.refreshFingerprint(relativePath: asset.relativePath, in: libraryURL)

        // Clean up the working directory so no in-progress copies linger.
        try? FileManager.default.removeItem(
            at: libraryURL.appendingPathComponent(".catalog/editing", isDirectory: true))

        if let markerError { throw markerError }
    }

    /// Re-fingerprints a video whose bytes just changed, replacing (or, when
    /// the file can't be read, clearing) its cache entry so the duplicate scan
    /// never sees a stale print and the next scan doesn't re-decode. Best
    /// effort — the cache is regenerable.
    static func refreshFingerprint(relativePath: String, in libraryURL: URL) async {
        let url = libraryURL.appendingPathComponent(relativePath)
        var prints = FrameFingerprintStore(libraryURL: libraryURL)
        let hashes = await VideoDuplicateAnalyzer.intervalFingerprint(videoURL: url)
        if hashes.isEmpty {
            prints.removeEntry(relativePath: relativePath)
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 {
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            prints.setHashes(hashes, relativePath: relativePath, sizeBytes: size, modified: mtime)
        }
        prints.save()
    }
}
