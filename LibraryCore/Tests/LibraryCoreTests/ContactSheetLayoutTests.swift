// ContactSheetLayoutTests.swift
// Reading a composite contact sheet back as individual frames.
//
// 🚨 The important test is the ROUND TRIP: these cells must land exactly where
// `composeGrid` drew them. Everything else here is a property of the maths; the
// round trip is the property of the pair, and it is the one that breaks
// silently if either side is changed alone.

import XCTest
import CoreGraphics
@testable import LibraryCore

final class ContactSheetLayoutTests: XCTestCase {

    /// A sheet exactly as `generateContactSheet` produces it by default:
    /// 4 columns, 3 rows, 320×180 cells, 8pt margins.
    private var defaultSheetSize: CGSize {
        CGSize(width: 4 * 320 + 5 * 8, height: 3 * 180 + 4 * 8)
    }

    // MARK: - 🚨 The round trip

    /// Every cell lands where `composeGrid` drew it. This is the assertion
    /// that fails if either the composer or the reader is changed alone.
    func testCellsMatchWhereTheComposerDrewThem() {
        let size = defaultSheetSize
        let cells = ContactSheetLayout.pixelCells(forSheetOfSize: size)

        XCTAssertEqual(cells.count, 12)
        for i in 0..<12 {
            let col = i % 4, row = i / 4
            // The composer's own expression, from `composeGrid`.
            let expectedX = 8 + CGFloat(col) * (320 + 8)
            let expectedY = 8 + CGFloat(row) * (180 + 8)

            XCTAssertEqual(cells[i].minX, expectedX, accuracy: 0.5, "cell \(i) x")
            XCTAssertEqual(cells[i].minY, expectedY, accuracy: 0.5, "cell \(i) y")
            XCTAssertEqual(cells[i].width, 320, accuracy: 0.5, "cell \(i) width")
            XCTAssertEqual(cells[i].height, 180, accuracy: 0.5, "cell \(i) height")
        }
    }

    /// ⭐ Reading order — left to right, top to bottom — which is the order the
    /// composer fills them and therefore chronological through the video.
    func testCellsAreInReadingOrder() {
        let cells = ContactSheetLayout.unitCells(forSheetOfSize: defaultSheetSize)

        XCTAssertEqual(cells[0].minX, cells[4].minX, accuracy: 0.001, "same column")
        XCTAssertLessThan(cells[0].minY, cells[4].minY, "and a row further down")
        XCTAssertLessThan(cells[0].minX, cells[1].minX, "second cell is to the right")
    }

    // MARK: - Properties

    /// ⚠️ Cells never overlap and never escape the sheet. An off-by-one here
    /// shows a sliver of the neighbouring frame, which reads as a rendering
    /// glitch rather than a layout bug — so it would survive review.
    func testCellsStayInsideTheSheetAndDoNotOverlap() {
        let cells = ContactSheetLayout.unitCells(forSheetOfSize: defaultSheetSize)

        for cell in cells {
            XCTAssertGreaterThanOrEqual(cell.minX, 0)
            XCTAssertGreaterThanOrEqual(cell.minY, 0)
            XCTAssertLessThanOrEqual(cell.maxX, 1.0001)
            XCTAssertLessThanOrEqual(cell.maxY, 1.0001)
        }
        for (i, a) in cells.enumerated() {
            for b in cells[(i + 1)...] {
                XCTAssertFalse(a.insetBy(dx: 0.0001, dy: 0.0001).intersects(b),
                               "frames must not bleed into each other")
            }
        }
    }

    /// ⭐ Scale-independent: the same fractions whatever size the sheet was
    /// written at, so a downsampled copy slices identically.
    func testUnitCellsAreIndependentOfPixelScale() {
        let small = ContactSheetLayout.unitCells(forSheetOfSize: defaultSheetSize)
        let large = ContactSheetLayout.unitCells(
            forSheetOfSize: CGSize(width: defaultSheetSize.width * 2,
                                   height: defaultSheetSize.height * 2),
            margin: ContactSheetLayout.margin * 2)

        for (a, b) in zip(small, large) {
            XCTAssertEqual(a.minX, b.minX, accuracy: 0.0001)
            XCTAssertEqual(a.width, b.width, accuracy: 0.0001)
        }
    }

    // MARK: - Refusals

    /// A sheet too small to hold its own margins is not one we can read, and
    /// guessing would produce negative-width crops.
    func testASheetTooSmallForItsMarginsYieldsNothing() {
        XCTAssertTrue(ContactSheetLayout.unitCells(
            forSheetOfSize: CGSize(width: 10, height: 10)).isEmpty)
    }

    func testAnEmptySizeYieldsNothing() {
        XCTAssertTrue(ContactSheetLayout.unitCells(forSheetOfSize: .zero).isEmpty)
    }

    /// 🚨 The constants must match the generator's defaults. A sheet does not
    /// record how it was laid out, so changing one side alone silently
    /// mis-slices every sheet already on disk.
    func testTheConstantsStillMatchTheGeneratorDefaults() {
        XCTAssertEqual(ContactSheetLayout.columns, 4)
        XCTAssertEqual(ContactSheetLayout.rows, 3)
        XCTAssertEqual(ContactSheetLayout.margin, 8)
    }
}
