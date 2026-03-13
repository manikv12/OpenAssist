import XCTest
@testable import OpenAssist

final class TokenUsageSnapshotTests: XCTestCase {
    func testExactContextSummaryShowsUsedAndWindowCounts() {
        let usage = TokenUsageSnapshot(
            last: TokenUsageBreakdown(inputTokens: 12_480, totalTokens: 15_000),
            total: .zero,
            modelContextWindow: 128_000
        )

        XCTAssertEqual(usage.exactContextSummary, "12,480 of 128,000 tokens")
    }

    func testContextTooltipDetailShowsPercentAndRemainingTokens() {
        let usage = TokenUsageSnapshot(
            last: TokenUsageBreakdown(inputTokens: 12_480, totalTokens: 15_000),
            total: .zero,
            modelContextWindow: 128_000
        )

        XCTAssertEqual(usage.contextTooltipDetail, "10% of context used - 115,520 left")
    }

    func testContextTooltipDetailFallsBackWithoutWindow() {
        let usage = TokenUsageSnapshot(
            last: TokenUsageBreakdown(inputTokens: 987, totalTokens: 1_100),
            total: .zero,
            modelContextWindow: nil
        )

        XCTAssertEqual(usage.exactContextSummary, "987 tokens")
        XCTAssertEqual(usage.contextTooltipDetail, "Current context in this chat")
    }
}
