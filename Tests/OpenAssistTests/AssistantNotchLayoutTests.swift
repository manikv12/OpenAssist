import XCTest
@testable import OpenAssist

final class AssistantNotchLayoutTests: XCTestCase {
    func testRevealZoneWrapsAroundHiddenHandle() {
        let hiddenFrame = NSRect(x: 100, y: 900, width: 180, height: 32)

        let zone = AssistantNotchLayout.revealZone(
            for: hiddenFrame,
            horizontalPadding: 18,
            minimumHoverHeight: 18,
            verticalPadding: 10
        )

        XCTAssertLessThan(zone.minX, hiddenFrame.minX)
        XCTAssertLessThan(zone.minY, hiddenFrame.minY)
        XCTAssertGreaterThan(zone.maxX, hiddenFrame.maxX)
        XCTAssertGreaterThan(zone.maxY, hiddenFrame.maxY)
    }

    func testVerticalOffsetOnlyAppliesToRealNotchContent() {
        XCTAssertEqual(
            AssistantNotchLayout.contentTopInset(
                hasHardwareNotch: true,
                topBandHeight: 36,
                safeAreaTop: 34,
                spacingBelowNotch: 8
            ),
            44,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AssistantNotchLayout.verticalOffset(
                hasHardwareNotch: true,
                topBandHeight: 36,
                safeAreaTop: 34,
                hiddenHeight: 32,
                requestedHeight: 32,
                collapsedHeight: 50,
                spacingBelowNotch: 8
            ),
            0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AssistantNotchLayout.verticalOffset(
                hasHardwareNotch: true,
                topBandHeight: 36,
                safeAreaTop: 34,
                hiddenHeight: 32,
                requestedHeight: 50,
                collapsedHeight: 50,
                spacingBelowNotch: 8
            ),
            44,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AssistantNotchLayout.verticalOffset(
                hasHardwareNotch: true,
                topBandHeight: 36,
                safeAreaTop: 34,
                hiddenHeight: 32,
                requestedHeight: 162,
                collapsedHeight: 50,
                spacingBelowNotch: 8
            ),
            0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AssistantNotchLayout.verticalOffset(
                hasHardwareNotch: false,
                topBandHeight: 36,
                safeAreaTop: 34,
                hiddenHeight: 32,
                requestedHeight: 50,
                collapsedHeight: 50,
                spacingBelowNotch: 8
            ),
            0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AssistantNotchLayout.contentTopInset(
                hasHardwareNotch: false,
                topBandHeight: 36,
                safeAreaTop: 34,
                spacingBelowNotch: 8
            ),
            0,
            accuracy: 0.001
        )
    }

    func testCollapsedDockPaddingCanRestoreFullHoverTarget() {
        let hiddenFrame = NSRect(x: 100, y: 900, width: 160, height: 4)
        let collapsedWidth: CGFloat = 320
        let collapsedHeight: CGFloat = 50

        let zone = AssistantNotchLayout.revealZone(
            for: hiddenFrame,
            horizontalPadding: (collapsedWidth - hiddenFrame.width) / 2,
            minimumHoverHeight: collapsedHeight,
            verticalPadding: (collapsedHeight - hiddenFrame.height) / 2
        )

        XCTAssertEqual(zone.width, collapsedWidth, accuracy: 0.001)
        XCTAssertEqual(zone.height, collapsedHeight, accuracy: 0.001)
        XCTAssertTrue(zone.contains(NSPoint(x: hiddenFrame.midX, y: hiddenFrame.midY)))
    }
}
