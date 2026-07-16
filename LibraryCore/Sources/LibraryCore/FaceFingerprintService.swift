// FaceFingerprintService.swift
// Face detection and visual-similarity fingerprints via stock Vision APIs,
// with a content-hash-keyed disk cache under .catalog/facePrints. See the
// class doc comment for the important recognition-vs-similarity caveat.

import Vision
import CoreGraphics
import Foundation

public enum FaceFingerprintError: Error {
    case noFeaturePrint
    case writeFailed
}

/// Detects faces and computes a rough visual "fingerprint" for them using
/// stock Vision framework APIs only — no bundled model, no network calls.
///
/// Important limitation: Vision does not expose a public face-*recognition*
/// API (that technology is reserved for Face ID / Photos' private models).
/// `VNGenerateImageFeaturePrintRequest` is a general-purpose visual-similarity
/// embedding, not one trained specifically to discriminate between human
/// faces. This makes for a genuinely useful "these look similar, take a
/// look" suggestion tool, but it is not confident identification — false
/// positives and misses are expected, especially across different angles,
/// lighting, or hairstyles. Callers must always treat results as suggestions
/// requiring user confirmation, never as an automatic tag.
public final class FaceFingerprintService {
    public init() {}

    // MARK: - Detection

    /// Detects faces in `image` and returns cropped face images, largest
    /// (by normalized area) first. Each crop is padded ~15% beyond Vision's
    /// tight face rectangle to include a bit of surrounding context.
    public func detectFaceCrops(in image: CGImage) throws -> [CGImage] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results else { return [] }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        let crops: [(area: CGFloat, image: CGImage)] = observations.compactMap { observation in
            // Vision's boundingBox is normalized (0...1) with origin at the
            // bottom-left. Pad for context, clamp to the image bounds, then
            // convert to the CGImage's own pixel space for cropping. Cropping
            // works in the image's natural top-left-row-0 layout — no
            // further flip is needed beyond this origin conversion.
            let box = observation.boundingBox
            let padded = box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.15)
            let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clamped.isEmpty else { return nil }

            let pixelRect = CGRect(
                x: clamped.origin.x * width,
                y: (1 - clamped.origin.y - clamped.height) * height,
                width: clamped.width * width,
                height: clamped.height * height
            ).integral

            guard let cropped = image.cropping(to: pixelRect) else { return nil }
            return (clamped.width * clamped.height, cropped)
        }

        return crops.sorted { $0.area > $1.area }.map(\.image)
    }

    // MARK: - Feature prints

    public func featurePrint(for image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceFingerprintError.noFeaturePrint
        }
        return observation
    }

    /// Lower is more similar. Returns nil if the two prints aren't
    /// comparable (e.g. produced by incompatible Vision revisions).
    public static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var result: Float = 0
        do {
            try a.computeDistance(&result, to: b)
            return result
        } catch {
            return nil
        }
    }

    // MARK: - Disk cache, keyed by content hash of the source photo

    public func cachedFingerprint(contentHash: String, libraryURL: URL) -> VNFeaturePrintObservation? {
        let url = fingerprintCacheURL(contentHash: contentHash, libraryURL: libraryURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    public func cacheFingerprint(_ observation: VNFeaturePrintObservation, contentHash: String, libraryURL: URL) throws {
        let url = fingerprintCacheURL(contentHash: contentHash, libraryURL: libraryURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        try data.write(to: url)
    }

    private func fingerprintCacheURL(contentHash: String, libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent(".catalog/facePrints/\(contentHash).dat")
    }
}
