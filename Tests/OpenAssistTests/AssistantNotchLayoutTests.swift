import XCTest
@testable import OpenAssist

final class AssistantNotchLayoutTests: XCTestCase {
    func testVerticalOffsetPrefersVisibleTopInsetForTallContent() {
        let offset = AssistantNotchLayout.verticalOffset(
            topBandHeight: 16,
            safeAreaTop: 0,
            visibleTopInset: 37,
            hiddenHeight: 24,
            requestedHeight: 480,
            spacingBelowNotch: 8
        )

        XCTAssertEqual(offset, 45)
    }

    func testVerticalOffsetKeepsHiddenDockInsideNotch() {
        let offset = AssistantNotchLayout.verticalOffset(
            topBandHeight: 16,
            safeAreaTop: 0,
            visibleTopInset: 37,
            hiddenHeight: 24,
            requestedHeight: 24,
            spacingBelowNotch: 8
        )

        XCTAssertEqual(offset, 0)
    }

    func testVerticalOffsetFallsBackToVisibleTopInsetWithoutHardwareGap() {
        let offset = AssistantNotchLayout.verticalOffset(
            topBandHeight: 0,
            safeAreaTop: 0,
            visibleTopInset: 37,
            hiddenHeight: 4,
            requestedHeight: 480,
            spacingBelowNotch: 8
        )

        XCTAssertEqual(offset, 45)
    }

    func testVerticalOffsetKeepsSyntheticHiddenDockAtScreenTop() {
        let offset = AssistantNotchLayout.verticalOffset(
            topBandHeight: 0,
            safeAreaTop: 0,
            visibleTopInset: 37,
            hiddenHeight: 4,
            requestedHeight: 4,
            spacingBelowNotch: 8
        )

        XCTAssertEqual(offset, 0)
    }
}
