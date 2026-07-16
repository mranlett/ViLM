// ContactSheetLayout.swift
// The grid geometry of a generated contact sheet, shared between the writer
// (ContactSheetService) and readers (face suggestion analysis) so cached
// sheets are always read back with the boundaries they were drawn with.

import CoreGraphics

/// The grid geometry of a generated contact sheet — how many cells, how big,
/// how much margin. `ContactSheetService.generateContactSheet` draws using
/// these exact numbers (see its default parameters); this type exists so
/// anything that needs to read cells back out of an already-cached contact
/// sheet (face suggestion analysis) can never disagree with how it was
/// written. If `generateContactSheet`'s defaults ever change, update
/// `.default` here to match, or every previously-cached sheet on disk would
/// be read back with the wrong cell boundaries.
public struct ContactSheetLayout: Sendable {
    public let columns: Int
    public let rows: Int
    public let cellSize: CGSize
    public let margin: CGFloat

    public init(columns: Int, rows: Int, cellSize: CGSize, margin: CGFloat) {
        self.columns = columns
        self.rows = rows
        self.cellSize = cellSize
        self.margin = margin
    }

    /// Mirrors `ContactSheetService.generateContactSheet`'s default parameters.
    public static let `default` = ContactSheetLayout(
        columns: 4,
        rows: 3,
        cellSize: CGSize(width: 320, height: 180),
        margin: 8
    )

    public var frameCount: Int { columns * rows }

    /// The full rendered sheet's pixel dimensions, matching
    /// `ContactSheetService.composeGrid`'s `sheetWidth`/`sheetHeight` math
    /// (a margin also runs along the far edge past the last cell).
    public var sheetSize: CGSize {
        CGSize(
            width: CGFloat(columns) * cellSize.width + CGFloat(columns + 1) * margin,
            height: CGFloat(rows) * cellSize.height + CGFloat(rows + 1) * margin
        )
    }

    /// The cell rect for (row, col) in the *rendered* CGImage's own pixel
    /// space (top-left origin, row 0 = the visual top row). This is the
    /// space `CGImage.cropping(to:)` expects — not the bottom-left
    /// CGContext coordinate space `composeGrid` uses only while drawing.
    public func cellRect(row: Int, col: Int) -> CGRect {
        CGRect(
            x: margin + CGFloat(col) * (cellSize.width + margin),
            y: margin + CGFloat(row) * (cellSize.height + margin),
            width: cellSize.width,
            height: cellSize.height
        )
    }
}
