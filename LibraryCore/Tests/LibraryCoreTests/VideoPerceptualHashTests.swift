import XCTest
@testable import LibraryCore

/// The perceptual video fingerprint.
///
/// Every constant in this algorithm is fixed by interoperability with an
/// external database rather than chosen. A "tidier" greyscale weight or a
/// corrected sprite orientation still produces a confident-looking 64-bit
/// value — it just matches nothing, and the only symptom is that lookups
/// quietly stop finding anything. These tests pin the arithmetic so that
/// failure shows up here instead.
final class VideoPerceptualHashTests: XCTestCase {

    // MARK: - Sampling

    func testSamplesTwentyFiveFramesAcrossTheMiddleNinetyPercent() {
        let times = VideoPerceptualHash.sampleTimes(duration: 1000)
        XCTAssertEqual(times.count, 25)
        XCTAssertEqual(times.first!, 50, accuracy: 0.001, "starts 5% in")
        // Last sample begins the final chunk, so it sits one step short of 95%.
        XCTAssertEqual(times.last!, 50 + 24 * 36, accuracy: 0.001)
        XCTAssertLessThan(times.last!, 950, "never reaches the closing 5%")
    }

    /// Skipping the ends is deliberate: idents and end cards are shared across
    /// a studio's whole catalogue and would drag unrelated videos together.
    func testSkipsOpeningAndClosing() {
        let times = VideoPerceptualHash.sampleTimes(duration: 100)
        XCTAssertGreaterThanOrEqual(times.first!, 5)
        XCTAssertLessThanOrEqual(times.last!, 95)
    }

    func testRefusesNonsenseDurations() {
        XCTAssertTrue(VideoPerceptualHash.sampleTimes(duration: 0).isEmpty)
        XCTAssertTrue(VideoPerceptualHash.sampleTimes(duration: -10).isEmpty)
        XCTAssertTrue(VideoPerceptualHash.sampleTimes(duration: .infinity).isEmpty)
    }

    // MARK: - Greyscale

    func testLuminanceReproducesTheReferenceWeights() {
        XCTAssertEqual(VideoPerceptualHash.luminance(r: 255, g: 255, b: 255),
                       0.299 * 255 + 0.587 * 255 + 0.114 * 255, accuracy: 1e-9)
        XCTAssertEqual(VideoPerceptualHash.luminance(r: 0, g: 0, b: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(VideoPerceptualHash.luminance(r: 0, g: 255, b: 0),
                       0.587 * 255, accuracy: 1e-9)
    }

    /// The reference divides blue by 256 and the other channels by 257. On
    /// 8-bit input that is a no-op — integer truncation gives the same answer
    /// for all 256 values — so the odd divisor is harmless here and is kept
    /// only to stay a faithful port. Pinned because it looks like a bug and
    /// would otherwise be "fixed" by someone reading it in isolation.
    func testTheOddBlueDivisorIsAnIdentityOnEightBitInput() {
        for value in 0...255 {
            let asBlue = VideoPerceptualHash.luminance(r: 0, g: 0, b: UInt8(value))
            XCTAssertEqual(asBlue, 0.114 * Double(value), accuracy: 1e-9,
                           "blue \(value) must behave as a plain 8-bit level")
        }
    }

    // MARK: - DCT

    func testDCTOfAConstantPutsAllEnergyInTheFirstCoefficient() {
        let out = VideoPerceptualHash.dct([Double](repeating: 5, count: 8))
        XCTAssertEqual(out[0], 40, accuracy: 1e-9, "unscaled: N * value")
        for k in 1..<8 { XCTAssertEqual(out[k], 0, accuracy: 1e-9) }
    }

    // MARK: - Hashing

    /// A flat field puts all its energy in the DC term, so the top bit is set.
    ///
    /// The remaining 63 coefficients are mathematically zero but land on
    /// floating-point residuals around 1e-13, roughly half above the median and
    /// half below — so their bits are noise, not signal. That only happens for
    /// a perfectly uniform image, which no real frame is, but it is the reason
    /// this asserts the DC bit rather than an exact value.
    func testFlatImageSetsTheDCBit() {
        let flat = [Double](repeating: 128, count: 64 * 64)
        let value = VideoPerceptualHash.hash(greyscale64: flat)
        XCTAssertNotNil(value)
        XCTAssertEqual(value! >> 63, 1, "first coefficient occupies the most significant bit")
    }

    /// The same input must always give the same hash — a lookup key that
    /// wandered would be worse than no key at all.
    func testHashingIsDeterministic() {
        var image = [Double](repeating: 0, count: 64 * 64)
        for row in 0..<64 {
            for col in 0..<64 { image[row * 64 + col] = Double((row * 7 + col * 13) % 251) }
        }
        let first = VideoPerceptualHash.hash(greyscale64: image)
        let second = VideoPerceptualHash.hash(greyscale64: image)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testWrongSizedInputIsRefused() {
        XCTAssertNil(VideoPerceptualHash.hash(greyscale64: [Double](repeating: 0, count: 100)))
    }

    /// A gradient must not hash to the same value as a flat field — the basic
    /// property the whole thing depends on.
    func testDifferentImagesHashDifferently() {
        var gradient = [Double](repeating: 0, count: 64 * 64)
        for row in 0..<64 {
            for col in 0..<64 { gradient[row * 64 + col] = Double(row * 4) }
        }
        let flat = [Double](repeating: 128, count: 64 * 64)
        XCTAssertNotEqual(VideoPerceptualHash.hash(greyscale64: gradient),
                          VideoPerceptualHash.hash(greyscale64: flat))
    }

    /// Bit order is part of the wire format: the first coefficient is the most
    /// significant bit, so a hex string starting with `8` or higher means the
    /// DC term is set.
    func testHexFormatIsSixteenLowercaseDigits() {
        XCTAssertEqual(VideoPerceptualHash.hexString(1 << 63), "8000000000000000")
        XCTAssertEqual(VideoPerceptualHash.hexString(0xb39180ee9fc3a0f1), "b39180ee9fc3a0f1")
    }

    // MARK: - Distance

    func testDistanceCountsDifferingBits() {
        XCTAssertEqual(VideoPerceptualHash.distance(0, 0), 0)
        XCTAssertEqual(VideoPerceptualHash.distance(0, 0b1011), 3)
        XCTAssertEqual(VideoPerceptualHash.distance(.max, 0), 64)
    }

    /// Two recorded values for the same real video, taken from the live
    /// database. Different encodes of one scene land a couple of bits apart —
    /// which is why matching needs a tolerance and equality is too strict a
    /// test of "same video".
    func testKnownVariantsOfOneVideoAreCloseTogether() {
        let a: UInt64 = 0xb39580ee9fc3a0b1
        let b: UInt64 = 0xb39180ee9fc3a0f1
        XCTAssertEqual(VideoPerceptualHash.distance(a, b), 2)
        XCTAssertLessThanOrEqual(VideoPerceptualHash.distance(a, b), 8)
    }

    /// Unrelated content sits near 32 bits apart — chance, on 64 bits. Worth
    /// pinning so a threshold is never set anywhere near it.
    func testUnrelatedHashesAreFarApart() {
        let a: UInt64 = 0xb39580ee9fc3a0b1   // one scene
        let b: UInt64 = 0xf10995d8a1a793e5   // an unrelated one
        XCTAssertGreaterThan(VideoPerceptualHash.distance(a, b), 16)
    }
}
