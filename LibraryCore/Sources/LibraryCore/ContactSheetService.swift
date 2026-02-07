import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class ContactSheetService {
    private let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - Public API

    /// Generates the "main" thumbnail for an asset if it doesn't already exist.
    /// iOS MVP: no scrubber selection; we just pick a reasonable default time.
    public func generateSingleThumbnail(
        for asset: Asset,
        libraryURL: URL,
        maxPixelSize: CGSize = CGSize(width: 640, height: 360),
        jpegQuality: CGFloat = 0.85,
        overwrite: Bool = false
    ) async throws {
        let videoURL = libraryURL.appendingPathComponent(asset.relativePath)
        let destinationURL = libraryURL
            .appendingPathComponent(".catalog/thumbnails/\(asset.id.uuidString).jpg")

        if !overwrite, FileManager.default.fileExists(atPath: destinationURL.path) { return }

        try ensureCatalogSubdirectoriesExist(libraryURL: libraryURL)

        let avAsset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxPixelSize

        let durationSeconds = try await avAsset.load(.duration).seconds
        let captureSeconds = pickDefaultThumbnailSecond(durationSeconds: durationSeconds)

        let cgImage = try await generateImage(generator: generator, seconds: captureSeconds)

        try writeJPEG(cgImage: cgImage, to: destinationURL, quality: jpegQuality)
    }


    /// Generates a contact sheet image for an asset (grid of frames).
    public func generateContactSheet(
        for asset: Asset,
        libraryURL: URL,
        columns: Int = 4,
        rows: Int = 3,
        cellSize: CGSize = CGSize(width: 320, height: 180),
        margin: CGFloat = 8,
        backgroundGray: CGFloat = 0.10,
        jpegQuality: CGFloat = 0.85
    ) async throws {
        let videoURL = libraryURL.appendingPathComponent(asset.relativePath)
        let destinationURL = libraryURL
            .appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg")

        if FileManager.default.fileExists(atPath: destinationURL.path) { return }

        try ensureCatalogSubdirectoriesExist(libraryURL: libraryURL)

        let avAsset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = cellSize

        let durationSeconds = try await avAsset.load(.duration).seconds
        let frameCount = max(1, columns * rows)

        // Avoid 0s and the very end (often black / fade-out).
        let times = sampleTimes(durationSeconds: durationSeconds, frameCount: frameCount)

        // Pull frames (best-effort: if some fail, we still build with what we have).
        var images: [CGImage] = []
        images.reserveCapacity(frameCount)

        for t in times {
            do {
                let img = try await generateImage(generator: generator, seconds: t)
                images.append(img)
            } catch {
                // Keep going; MVP: don’t fail the entire sheet because 1 frame failed.
                // You can tighten this later if you want strictness.
                continue
            }
        }

        guard !images.isEmpty else { return }

        let sheetImage = composeGrid(
            images: images,
            columns: columns,
            rows: rows,
            cellSize: cellSize,
            margin: margin,
            backgroundGray: backgroundGray
        )

        try writeJPEG(cgImage: sheetImage, to: destinationURL, quality: jpegQuality)
    }

    // MARK: - Helpers

    private func ensureCatalogSubdirectoriesExist(libraryURL: URL) throws {
        let catalogURL = libraryURL.appendingPathComponent(".catalog")
        let thumbsURL = catalogURL.appendingPathComponent("thumbnails")
        let sheetsURL = catalogURL.appendingPathComponent("contactSheets")

        try FileManager.default.createDirectory(at: thumbsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sheetsURL, withIntermediateDirectories: true)
    }

    private func pickDefaultThumbnailSecond(durationSeconds: Double) -> Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }

        // Heuristic:
        // - If very short, pick middle
        // - Otherwise pick ~10% in (often avoids black first frame / intro slate)
        if durationSeconds < 20 {
            return durationSeconds * 0.5
        } else {
            return min(max(durationSeconds * 0.10, 1.0), durationSeconds - 1.0)
        }
    }

    private func sampleTimes(durationSeconds: Double, frameCount: Int) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0, frameCount > 0 else {
            return Array(repeating: 0, count: max(1, frameCount))
        }

        let start = min(1.0, max(0, durationSeconds * 0.02))
        let end = max(start, durationSeconds * 0.98)

        if frameCount == 1 { return [(start + end) * 0.5] }

        let step = (end - start) / Double(frameCount + 1)
        return (1...frameCount).map { start + step * Double($0) }
    }

    private func generateImage(generator: AVAssetImageGenerator, seconds: Double) async throws -> CGImage {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)

        return try await withCheckedThrowingContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                guard result == .succeeded, let cgImage else {
                    cont.resume(throwing: NSError(
                        domain: "ContactSheetService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to generate frame image."]
                    ))
                    return
                }
                cont.resume(returning: cgImage)
            }
        }
    }

    private func composeGrid(
        images: [CGImage],
        columns: Int,
        rows: Int,
        cellSize: CGSize,
        margin: CGFloat,
        backgroundGray: CGFloat
    ) -> CGImage {
        let cols = max(1, columns)
        let rws = max(1, rows)

        let sheetWidth = CGFloat(cols) * cellSize.width + CGFloat(cols + 1) * margin
        let sheetHeight = CGFloat(rws) * cellSize.height + CGFloat(rws + 1) * margin

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let ctx = CGContext(
            data: nil,
            width: Int(sheetWidth),
            height: Int(sheetHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!

        // Background
        ctx.setFillColor(CGColor(gray: backgroundGray, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

        // Draw cells (note: CoreGraphics origin is bottom-left)
        let maxCells = cols * rws
        let toDraw = min(images.count, maxCells)

        for i in 0..<toDraw {
            let col = i % cols
            let row = i / cols

            let x = margin + CGFloat(col) * (cellSize.width + margin)
            let yFromTop = margin + CGFloat(row) * (cellSize.height + margin)
            let y = sheetHeight - yFromTop - cellSize.height

            let rect = CGRect(x: x, y: y, width: cellSize.width, height: cellSize.height)

            // Scale-to-fill while preserving aspect ratio (center-crop)
            let img = images[i]
            drawAspectFill(image: img, in: rect, context: ctx)
        }

        return ctx.makeImage()!
    }

    private func drawAspectFill(image: CGImage, in rect: CGRect, context ctx: CGContext) {
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)

        guard iw > 0, ih > 0 else { return }

        let scale = max(rect.width / iw, rect.height / ih)
        let scaledW = iw * scale
        let scaledH = ih * scale

        let dx = rect.midX - scaledW / 2
        let dy = rect.midY - scaledH / 2

        let drawRect = CGRect(x: dx, y: dy, width: scaledW, height: scaledH)

        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()
    }

    private func writeJPEG(cgImage: CGImage, to url: URL, quality: CGFloat) throws {
        let cfURL = url as CFURL

        guard let destination = CGImageDestinationCreateWithURL(
            cfURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "ContactSheetService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination."]
            )
        }

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))
        ]

        CGImageDestinationAddImage(destination, cgImage, props as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(
                domain: "ContactSheetService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize JPEG write."]
            )
        }
    }
}
