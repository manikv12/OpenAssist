import XCTest
@testable import OpenAssist

final class WaveformMeterEngineTests: XCTestCase {
    func testProcessedLevelSuppressesSmallNoise() {
        XCTAssertEqual(WaveformMeterEngine.processedLevel(from: 0.03), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(WaveformMeterEngine.processedLevel(from: 0.30), 0)
    }

    func testTickFollowsProvidedWaveformBars() {
        var engine = WaveformMeterEngine()

        engine.updateTargetLevel(0.7)
        engine.updateTargetBarLevels([0.10, 0.22, 0.52, 0.78, 0.44, 0.18, 0.08])
        for _ in 0..<6 {
            engine.tick()
        }

        XCTAssertGreaterThan(engine.level, 0.2)
        XCTAssertEqual(engine.barLevels.count, WaveformMeterEngine.barCount)
        XCTAssertGreaterThan(engine.barLevels[3], engine.barLevels[0])
        XCTAssertGreaterThan(engine.barLevels[2], engine.barLevels[1])
        XCTAssertGreaterThan(engine.barLevels[4], engine.barLevels[5])
    }

    func testFirstTickRespondsQuicklyToNewSpeech() {
        var engine = WaveformMeterEngine()

        engine.updateTargetLevel(0.75)
        engine.updateTargetBarLevels([0.08, 0.18, 0.42, 0.72, 0.46, 0.20, 0.10])
        engine.tick()

        XCTAssertGreaterThan(engine.level, 0.25)
        XCTAssertGreaterThan(engine.barLevels[3], 0.40)
        XCTAssertGreaterThan(engine.barLevels[2], 0.20)
    }

    func testBarsReleaseSmoothlyAfterSpeechDrops() {
        var engine = WaveformMeterEngine()

        engine.updateTargetLevel(1.0)
        engine.updateTargetBarLevels([0.22, 0.38, 0.64, 0.82, 0.60, 0.34, 0.16])
        for _ in 0..<10 {
            engine.tick()
        }

        let speakingLevel = engine.level
        let speakingCenterBar = engine.barLevels[3]

        engine.updateTargetLevel(0)
        engine.updateTargetBarLevels(Array(repeating: 0, count: WaveformMeterEngine.barCount))
        for _ in 0..<6 {
            engine.tick()
        }

        XCTAssertLessThan(engine.level, speakingLevel)
        XCTAssertLessThan(engine.barLevels[3], speakingCenterBar)
        XCTAssertGreaterThan(engine.barLevels[3], 0)
    }
}
