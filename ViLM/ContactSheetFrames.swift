// ContactSheetFrames.swift
// The stills a video can show, without ever opening the video.
//
// 🚨 Slices the contact sheet rather than re-extracting frames. A contact sheet
// is a single composite JPEG already on disk; pulling twelve frames out of the
// video again would mean an AVFoundation pass every time someone glanced at a
// contender, on screens whose whole point is speed.
//
// 🚨 And it is why Head to Head can run over videos at all (D1): the game is a
// rapid visual judgement, so a video must be judgeable from pictures. Nothing
// here decodes video or touches playback — a contender that started talking
// mid-session would end the session.

import Foundation
import ImageIO
import LibraryCore

enum ContactSheetFrames {

    /// Every still for `asset`, poster first.
    ///
    /// ⚠️ The poster leads deliberately. It is the image the operator has
    /// already seen in the grid, so opening onto a different frame reads as the
    /// wrong video.
    ///
    /// ⚠️ Resolves paths on the main actor — `LibrarySession` owns them — and
    /// does the decoding off it. Empty means "nothing generated yet", which
    /// every caller must be able to say out loud rather than showing black.
    @MainActor
    static func load(for assetID: Asset.ID) async -> [CGImage] {
        let posterURL = LibrarySession.shared.thumbnailURL(for: assetID)
        let sheetURL = LibrarySession.shared.contactSheetURL(for: assetID)

        return await Task.detached(priority: .userInitiated) {
            var out: [CGImage] = []
            if let posterURL, let poster = image(at: posterURL) { out.append(poster) }
            if let sheetURL, let sheet = image(at: sheetURL) {
                let size = CGSize(width: sheet.width, height: sheet.height)
                for rect in ContactSheetLayout.pixelCells(forSheetOfSize: size) {
                    // ⚠️ `cropping` returns nil for a rect outside the image,
                    // which is the correct answer for a sheet laid out
                    // differently from today's constants — skip, never crash.
                    if let cell = sheet.cropping(to: rect) { out.append(cell) }
                }
            }
            return out
        }.value
    }

    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
