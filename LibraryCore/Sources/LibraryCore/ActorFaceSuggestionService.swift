// ActorFaceSuggestionService.swift
// On-device face-based actor suggestion: rebuildFaceIndex caches a Vision
// fingerprint per actor photo (content-hash keyed), and suggestActors matches
// faces found in a video's contact sheet against those fingerprints. Results
// are heuristic visual similarity, never automatic identification.

import Vision
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RebuildFaceIndexResult: Sendable {
    public let actorsScanned: Int
    public let photosScanned: Int
    public let fingerprintsComputed: Int
}

/// A candidate actor match for a face detected in a video's contact sheet.
/// Always a suggestion for the user to confirm — never applied automatically.
public struct ActorFaceSuggestion: Identifiable, Sendable {
    public let id: UUID
    public let actorName: String
    /// A rough 0...1 heuristic — higher means more visually similar. Not a
    /// calibrated probability; see `FaceFingerprintService`'s doc comment.
    public let similarity: Double
    /// The detected face, cropped from the video's contact sheet, written to
    /// a temp file so it can be displayed without holding image data in memory.
    public let faceCropURL: URL

    public init(actorName: String, similarity: Double, faceCropURL: URL) {
        self.id = UUID()
        self.actorName = actorName
        self.similarity = similarity
        self.faceCropURL = faceCropURL
    }
}

extension LibraryStore {

    /// Every photo file currently cached on disk for an actor (primary +
    /// gallery), paired with the content hash used as its fingerprint cache
    /// key. Mirrors the enumeration logic used by Actor Library Export.
    func actorPhotoFiles(for profile: EntityProfile, libraryURL: URL) -> [(url: URL, contentHash: String)] {
        let profilesDir = libraryURL.appendingPathComponent(".catalog/profiles")
        var results: [(URL, String)] = []
        var seenFileNames = Set<String>()

        let primaryFileName = ProfileImageNaming.primaryFileName(for: profile.id)
        let primaryURL = profilesDir.appendingPathComponent(primaryFileName)
        if let data = try? Data(contentsOf: primaryURL) {
            seenFileNames.insert(primaryFileName)
            results.append((primaryURL, ProfileImageNaming.sha256Hex(data)))
        }

        for token in profile.galleryUrls {
            let isGalleryToken = token != profile.photoUrl && token != ProfileImageNaming.localPrimaryToken
            guard isGalleryToken else { continue }
            let fileName = ProfileImageNaming.galleryFileName(for: profile.id, token: token)
            guard !seenFileNames.contains(fileName) else { continue }
            let fileURL = profilesDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            seenFileNames.insert(fileName)
            results.append((fileURL, ProfileImageNaming.sha256Hex(data)))
        }

        return results
    }

    /// Ensures every actor's current photos have a cached face fingerprint,
    /// computing whatever's missing. Safe to re-run: a photo already cached
    /// under its content hash is skipped, so a repeat run only processes
    /// photos that are new or have changed since last time.
    @discardableResult
    public func rebuildFaceIndex(libraryURL: URL) throws -> RebuildFaceIndexResult {
        let service = FaceFingerprintService()
        let actorProfiles = try fetchAllEntityProfiles().filter { $0.id.hasPrefix("actor:") }

        var photosScanned = 0
        var fingerprintsComputed = 0

        for profile in actorProfiles {
            for (fileURL, contentHash) in actorPhotoFiles(for: profile, libraryURL: libraryURL) {
                photosScanned += 1
                if service.cachedFingerprint(contentHash: contentHash, libraryURL: libraryURL) != nil {
                    continue
                }
                guard let data = try? Data(contentsOf: fileURL),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                guard let faceCrops = try? service.detectFaceCrops(in: cgImage), let bestFace = faceCrops.first else { continue }
                guard let fingerprint = try? service.featurePrint(for: bestFace) else { continue }
                try? service.cacheFingerprint(fingerprint, contentHash: contentHash, libraryURL: libraryURL)
                fingerprintsComputed += 1
            }
        }

        return RebuildFaceIndexResult(
            actorsScanned: actorProfiles.count,
            photosScanned: photosScanned,
            fingerprintsComputed: fingerprintsComputed
        )
    }

    /// Analyzes a video's cached contact sheet for faces and suggests actors
    /// whose reference photos look visually similar, ranked closest first.
    /// Returns an empty array (never throws for "no results") if there's no
    /// contact sheet yet, no faces detected, or no actor has any cached
    /// reference fingerprint.
    public func suggestActors(for asset: Asset, libraryURL: URL, similarityThreshold: Double = 0.4) throws -> [ActorFaceSuggestion] {
        let contactSheetURL = libraryURL.appendingPathComponent(".catalog/contactSheets/\(asset.id.uuidString).jpg")
        guard let sheetData = try? Data(contentsOf: contactSheetURL),
              let source = CGImageSourceCreateWithData(sheetData as CFData, nil),
              let sheetImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }

        let service = FaceFingerprintService()
        let layout = ContactSheetLayout.default

        // Keep the reference index current before matching against it.
        _ = try? rebuildFaceIndex(libraryURL: libraryURL)

        let actorProfiles = try fetchAllEntityProfiles().filter { $0.id.hasPrefix("actor:") }
        let actorReferenceSets: [(name: String, fingerprints: [VNFeaturePrintObservation])] = actorProfiles.compactMap { profile in
            let fingerprints = actorPhotoFiles(for: profile, libraryURL: libraryURL).compactMap {
                service.cachedFingerprint(contentHash: $0.contentHash, libraryURL: libraryURL)
            }
            guard !fingerprints.isEmpty else { return nil }
            return (String(profile.id.dropFirst("actor:".count)), fingerprints)
        }
        guard !actorReferenceSets.isEmpty else { return [] }

        var suggestions: [ActorFaceSuggestion] = []
        // Crops live in a dedicated folder wiped at the start of each scan —
        // otherwise every scan leaks its face-crop JPEGs into tmp for the
        // life of the app container. Only the newest scan's sheet is ever
        // displaying these files, so clearing the previous batch is safe.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViLM-faceCrops", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for row in 0..<layout.rows {
            for col in 0..<layout.columns {
                guard let cellImage = sheetImage.cropping(to: layout.cellRect(row: row, col: col)) else { continue }
                guard let faceCrops = try? service.detectFaceCrops(in: cellImage) else { continue }

                for faceCrop in faceCrops {
                    guard let faceFingerprint = try? service.featurePrint(for: faceCrop) else { continue }

                    let matches: [(name: String, similarity: Double)] = actorReferenceSets.compactMap { actor in
                        let distances = actor.fingerprints.compactMap { FaceFingerprintService.distance(faceFingerprint, $0) }
                        guard let minDistance = distances.min() else { return nil }
                        let similarity = Self.similarityScore(forDistance: minDistance)
                        return similarity >= similarityThreshold ? (actor.name, similarity) : nil
                    }
                    guard !matches.isEmpty else { continue }
                    guard let cropURL = try? Self.writeTempJPEG(faceCrop, in: tempDir) else { continue }

                    for match in matches.sorted(by: { $0.similarity > $1.similarity }).prefix(3) {
                        suggestions.append(ActorFaceSuggestion(actorName: match.name, similarity: match.similarity, faceCropURL: cropURL))
                    }
                }
            }
        }

        return suggestions.sorted { $0.similarity > $1.similarity }
    }

    /// Vision's raw feature-print distance is unbounded (roughly 0 =
    /// identical, growing with dissimilarity). This heuristic maps it onto a
    /// rough 0...1 "similarity" scale for display and thresholding — a
    /// starting point to be tuned against real results, not a calibrated
    /// probability.
    static func similarityScore(forDistance distance: Float) -> Double {
        max(0, 1 - Double(distance) / 2.0)
    }

    private static func writeTempJPEG(_ image: CGImage, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FaceFingerprintError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FaceFingerprintError.writeFailed
        }
        return url
    }
}
