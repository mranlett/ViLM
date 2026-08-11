// ContactSheetLayout.swift
// Reading a contact sheet back as individual frames.
//
// 🚨 A contact sheet is ONE composite JPEG, not a folder of stills. Anything
// that wants to show its frames separately has to invert the geometry
// `composeGrid` used to lay them out — and the only safe way to do that is
// from the same constants, in one place, tested.
//
// ⚠️ The alternative was pixel arithmetic inside a view. Getting it slightly
// wrong shows a sliver of the neighbouring frame down one edge, which reads as
// a rendering glitch rather than as a layout bug, so it would have survived.

import Foundation
import CoreGraphics

public enum ContactSheetLayout {

    /// The values `ContactSheetService.generateContactSheet` uses by default,
    /// and every caller in this project relies on.
    ///
    /// 🚨 A sheet does not record how it was laid out. These must stay in step
    /// with that function's defaults — changing one without the other silently
    /// mis-slices every sheet already on disk.
    public static let columns = 4
    public static let rows = 3
    public static let margin: CGFloat = 8

    /// Where each frame sits, as fractions of the sheet, in TOP-LEFT
    /// coordinates.
    ///
    /// ⭐ Unit rects rather than pixels, so a caller can slice the full-size
    /// image or a downsampled copy with the same numbers.
    ///
    /// ⚠️ Returns cells in reading order — left to right, top to bottom —
    /// which is the order `composeGrid` fills them and therefore chronological.
    public static func unitCells(forSheetOfSize size: CGSize,
                                 columns: Int = columns,
                                 rows: Int = rows,
                                 margin: CGFloat = margin) -> [CGRect] {
        let cols = max(1, columns), rws = max(1, rows)
        guard size.width > 0, size.height > 0 else { return [] }

        // Inverted from `composeGrid`:
        //   sheetW = cols * cellW + (cols + 1) * margin
        let cellW = (size.width - CGFloat(cols + 1) * margin) / CGFloat(cols)
        let cellH = (size.height - CGFloat(rws + 1) * margin) / CGFloat(rws)
        // A sheet too small to hold the margins is not one we can read.
        guard cellW > 0, cellH > 0 else { return [] }

        return (0..<(cols * rws)).map { i in
            let col = i % cols, row = i / cols
            return CGRect(
                x: (margin + CGFloat(col) * (cellW + margin)) / size.width,
                y: (margin + CGFloat(row) * (cellH + margin)) / size.height,
                width: cellW / size.width,
                height: cellH / size.height)
        }
    }

    /// The same cells in pixels, for cropping a `CGImage`.
    public static func pixelCells(forSheetOfSize size: CGSize,
                                  columns: Int = columns,
                                  rows: Int = rows,
                                  margin: CGFloat = margin) -> [CGRect] {
        unitCells(forSheetOfSize: size, columns: columns, rows: rows, margin: margin)
            .map { CGRect(x: ($0.minX * size.width).rounded(),
                          y: ($0.minY * size.height).rounded(),
                          width: ($0.width * size.width).rounded(),
                          height: ($0.height * size.height).rounded()) }
    }
}
