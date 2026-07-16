import XCTest
@testable import OpenAssist

final class AssistantNotchInteractionTests: XCTestCase {
    func testHoverStateStartsWhenPointerBecomesEligible() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let state = AssistantNotchInteraction.updatedHoverState(
            current: .init(start: nil, displayID: nil),
            hoveredDisplayID: 42,
            isEligible: true,
            now: now
        )

        XCTAssertEqual(state.start, now)
        XCTAssertEqual(state.displayID, 42)
    }

    func testHoverStateResetsWhenPointerLeavesOrClicks() {
        let state = AssistantNotchInteraction.updatedHoverState(
            current: .init(start: Date(timeIntervalSinceReferenceDate: 100), displayID: 42),
            hoveredDisplayID: 42,
            isEligible: false,
            now: Date(timeIntervalSinceReferenceDate: 101)
        )

        XCTAssertNil(state.start)
        XCTAssertNil(state.displayID)
    }

    func testRevealRequiresFullHoverDelay() {
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(
            AssistantNotchInteraction.shouldReveal(
                hoverStart: start,
                now: Date(timeIntervalSinceReferenceDate: 101.9),
                revealDelay: 2.0
            )
        )
        XCTAssertTrue(
            AssistantNotchInteraction.shouldReveal(
                hoverStart: start,
                now: Date(timeIntervalSinceReferenceDate: 102.0),
                revealDelay: 2.0
            )
        )
    }

    func testMousePassthroughAllowedWhileDockIsHidden() {
        XCTAssertTrue(
            AssistantNotchInteraction.shouldAllowMousePassthrough(
                isDockRevealed: false,
                shouldDockCollapsed: true,
                isShowingCompactCard: false,
                isExpanded: false
            )
        )
        XCTAssertFalse(
            AssistantNotchInteraction.shouldAllowMousePassthrough(
                isDockRevealed: true,
                shouldDockCollapsed: true,
                isShowingCompactCard: false,
                isExpanded: false
            )
        )
    }
}
