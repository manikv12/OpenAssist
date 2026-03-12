import XCTest
@testable import OpenAssist

final class AudioWaveformShapeTests: XCTestCase {
    func testBinsStayZeroForSilence() {
        let samples = Array(repeating: Float(0), count: 256)
        let bins = samples.withUnsafeBufferPointer {
            AudioWaveformShape.bins(from: $0, count: 7)
        }

        XCTAssertEqual(bins, Array(repeating: 0, count: 7))
    }

    func testBinsCaptureChangingAmplitudeAcrossTime() {
        var samples: [Float] = []
        samples.append(contentsOf: Array(repeating: 0.02, count: 40))
        samples.append(contentsOf: Array(repeating: 0.10, count: 40))
        samples.append(contentsOf: Array(repeating: 0.28, count: 40))
        samples.append(contentsOf: Array(repeating: 0.55, count: 40))
        samples.append(contentsOf: Array(repeating: 0.30, count: 40))
        samples.append(contentsOf: Array(repeating: 0.12, count: 40))
        samples.append(contentsOf: Array(repeating: 0.04, count: 40))

        let bins = samples.withUnsafeBufferPointer {
            AudioWaveformShape.bins(from: $0, count: 7)
        }

        XCTAssertEqual(bins.count, 7)
        XCTAssertGreaterThan(bins[3], bins[1])
        XCTAssertGreaterThan(bins[2], bins[0])
        XCTAssertGreaterThan(bins[4], bins[6])
    }
}
