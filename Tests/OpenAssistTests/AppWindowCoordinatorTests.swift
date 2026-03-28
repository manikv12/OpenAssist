import AppKit
import XCTest
@testable import OpenAssist

final class AppWindowCoordinatorTests: XCTestCase {
    func testAdaptedMinimumSizeShrinksToFitSmallerVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 900, height: 580)

        let fittedMinimum = AppWindowFrameFitter.adaptedMinimumSize(
            preferredMinimumSize: NSSize(width: 980, height: 620),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(fittedMinimum.width, 876, accuracy: 0.5)
        XCTAssertEqual(fittedMinimum.height, 556, accuracy: 0.5)
    }

    func testFittedFramePreservesUserSizeWhenAlreadyWithinVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let existingFrame = NSRect(x: 120, y: 120, width: 1040, height: 700)

        let fittedFrame = AppWindowFrameFitter.fittedFrame(
            existingFrame,
            within: visibleFrame,
            minimumSize: NSSize(width: 980, height: 620)
        )

        XCTAssertEqual(fittedFrame.origin.x, existingFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(fittedFrame.origin.y, existingFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(fittedFrame.width, existingFrame.width, accuracy: 0.5)
        XCTAssertEqual(fittedFrame.height, existingFrame.height, accuracy: 0.5)
    }

    func testFittedFrameRecentersOversizedWindowInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1280, height: 720)
        let oversizedFrame = NSRect(x: -300, y: -200, width: 1600, height: 900)

        let fittedFrame = AppWindowFrameFitter.fittedFrame(
            oversizedFrame,
            within: visibleFrame,
            minimumSize: NSSize(width: 980, height: 620)
        )

        XCTAssertEqual(fittedFrame.width, visibleFrame.width, accuracy: 0.5)
        XCTAssertEqual(fittedFrame.height, visibleFrame.height, accuracy: 0.5)
        XCTAssertEqual(fittedFrame.origin.x, visibleFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(fittedFrame.origin.y, visibleFrame.origin.y, accuracy: 0.5)
    }
}
