import XCTest
@testable import OpenAssist

final class AccountRateLimitsTests: XCTestCase {
    func testSparkModelPrefersNonDefaultBucketWhenAvailable() throws {
        let limits = try XCTUnwrap(AccountRateLimits.fromPayload(fullRateLimitsPayload()))

        XCTAssertEqual(limits.additionalBuckets.map(\.limitID), ["codex_other"])
        XCTAssertEqual(limits.bucket(for: "gpt-5.4")?.limitID, "codex")
        XCTAssertEqual(limits.bucket(for: "gpt-5.3-codex-spark")?.limitID, "codex_other")
    }

    func testIncrementalDefaultUpdateKeepsExistingAdditionalBuckets() throws {
        let existing = try XCTUnwrap(AccountRateLimits.fromPayload(fullRateLimitsPayload()))
        let updated = try XCTUnwrap(
            AccountRateLimits.fromPayload(
                [
                    "rateLimits": [
                        "limitId": "codex",
                        "primary": [
                            "usedPercent": 19,
                            "windowDurationMins": 300
                        ],
                        "secondary": [
                            "usedPercent": 31,
                            "windowDurationMins": 10_080
                        ]
                    ]
                ],
                preserving: existing
            )
        )

        XCTAssertEqual(updated.additionalBuckets.map(\.limitID), ["codex_other"])
        XCTAssertEqual(updated.primary?.usedPercent, 19)
        XCTAssertEqual(updated.bucket(for: "gpt-5.3-codex-spark")?.limitID, "codex_other")
    }

    func testNonSparkModelDoesNotFallBackToSparkOnlyBucket() throws {
        let limits = try XCTUnwrap(
            AccountRateLimits.fromPayload(
                [
                    "rateLimits": [
                        "limitId": "codex_other",
                        "limitName": "GPT-5.3-Codex-Spark",
                        "primary": [
                            "usedPercent": 3,
                            "windowDurationMins": 300
                        ],
                        "secondary": [
                            "usedPercent": 8,
                            "windowDurationMins": 10_080
                        ]
                    ],
                    "rateLimitsByLimitId": [
                        "codex_other": [
                            "limitId": "codex_other",
                            "limitName": "GPT-5.3-Codex-Spark",
                            "primary": [
                                "usedPercent": 3,
                                "windowDurationMins": 300
                            ],
                            "secondary": [
                                "usedPercent": 8,
                                "windowDurationMins": 10_080
                            ]
                        ]
                    ]
                ]
            )
        )

        XCTAssertNil(limits.bucket(for: "gpt-5.4"))
        XCTAssertEqual(limits.bucket(for: "gpt-5.3-codex-spark")?.limitID, "codex_other")
    }

    func testStatusBarEntriesShowSparkFiveHourAndWeeklyWindows() throws {
        let bucket = AccountRateLimitBucket(
            limitID: "codex_other",
            limitName: "spark",
            primary: try XCTUnwrap(
                RateLimitWindow(from: [
                    "usedPercent": 77,
                    "windowDurationMins": 300
                ])
            ),
            secondary: try XCTUnwrap(
                RateLimitWindow(from: [
                    "usedPercent": 8,
                    "windowDurationMins": 10_080
                ])
            )
        )

        let entries = bucket.statusBarEntries(bucketLabel: "Spark")

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.window.windowLabel), ["5h", "Weekly"])
        XCTAssertEqual(entries.map(\.showsResetInline), [false, true])
    }

    private func fullRateLimitsPayload() -> [String: Any] {
        let codexSnapshot: [String: Any] = [
            "limitId": "codex",
            "primary": [
                "usedPercent": 12,
                "windowDurationMins": 300
            ],
            "secondary": [
                "usedPercent": 24,
                "windowDurationMins": 10_080
            ]
        ]

        let sparkSnapshot: [String: Any] = [
            "limitId": "codex_other",
            "limitName": "spark",
            "primary": [
                "usedPercent": 77,
                "windowDurationMins": 300
            ]
        ]

        return [
            "rateLimits": codexSnapshot,
            "rateLimitsByLimitId": [
                "codex": codexSnapshot,
                "codex_other": sparkSnapshot
            ]
        ]
    }
}
