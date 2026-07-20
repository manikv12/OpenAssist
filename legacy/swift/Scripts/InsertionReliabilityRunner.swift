import Foundation

@inline(__always)
func fail(_ message: String) -> Never {
    fputs("❌ \(message)\n", stderr)
    exit(1)
}

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fail(message)
    }
}

struct InsertionScenario {
    let name: String
    let text: String
    let copyToClipboard: Bool
    let directInsertSucceeded: Bool
    let typingInsertSucceeded: Bool
    let specialPasteSucceeded: Bool
    let expectedPath: InsertionPath
    let expectedResult: TextInserter.Result
}

@main
struct InsertionReliabilityRunner {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty || args.contains("--regression") {
            runRegressionSuite()
            return
        }

        if args.contains("--help") {
            printUsage()
            return
        }

        runSingleScenario(arguments: args)
    }

    private static func runRegressionSuite() {
        let scenarios: [InsertionScenario] = [
            InsertionScenario(
                name: "empty-text",
                text: "",
                copyToClipboard: true,
                directInsertSucceeded: false,
                typingInsertSucceeded: false,
                specialPasteSucceeded: false,
                expectedPath: .emptyInput,
                expectedResult: .empty
            ),
            InsertionScenario(
                name: "direct-priority",
                text: "hello",
                copyToClipboard: true,
                directInsertSucceeded: true,
                typingInsertSucceeded: true,
                specialPasteSucceeded: false,
                expectedPath: .directAccessibility,
                expectedResult: .pasted
            ),
            InsertionScenario(
                name: "typing-fallback",
                text: "hello",
                copyToClipboard: true,
                directInsertSucceeded: false,
                typingInsertSucceeded: true,
                specialPasteSucceeded: false,
                expectedPath: .typedUnicodeEvents,
                expectedResult: .pasted
            ),
            InsertionScenario(
                name: "clipboard-special-paste-success",
                text: "hello",
                copyToClipboard: true,
                directInsertSucceeded: false,
                typingInsertSucceeded: false,
                specialPasteSucceeded: true,
                expectedPath: .specialPasteClipboard,
                expectedResult: .pasted
            ),
            InsertionScenario(
                name: "clipboard-special-paste-failure",
                text: "hello",
                copyToClipboard: true,
                directInsertSucceeded: false,
                typingInsertSucceeded: false,
                specialPasteSucceeded: false,
                expectedPath: .specialPasteClipboard,
                expectedResult: .copiedOnly
            ),
            InsertionScenario(
                name: "transient-clipboard-paste-success",
                text: "hello",
                copyToClipboard: false,
                directInsertSucceeded: false,
                typingInsertSucceeded: false,
                specialPasteSucceeded: true,
                expectedPath: .specialPasteTransientClipboard,
                expectedResult: .pasted
            ),
            InsertionScenario(
                name: "transient-clipboard-paste-failure",
                text: "hello",
                copyToClipboard: false,
                directInsertSucceeded: false,
                typingInsertSucceeded: false,
                specialPasteSucceeded: false,
                expectedPath: .specialPasteTransientClipboard,
                expectedResult: .notInserted
            )
        ]

        for scenario in scenarios {
            let decision = InsertionDecisionModel.evaluate(
                text: scenario.text,
                copyToClipboard: scenario.copyToClipboard,
                directInsertSucceeded: scenario.directInsertSucceeded,
                typingInsertSucceeded: scenario.typingInsertSucceeded,
                specialPasteSucceeded: scenario.specialPasteSucceeded
            )

            check(
                decision.path == scenario.expectedPath,
                "\(scenario.name): expected path \(scenario.expectedPath.rawValue), got \(decision.path.rawValue)"
            )
            check(
                decision.result == scenario.expectedResult,
                "\(scenario.name): expected result \(scenario.expectedResult.rawValue), got \(decision.result.rawValue)"
            )
        }

        print("✅ Insertion reliability regression suite passed (\(scenarios.count) scenarios)")
    }

    private static func runSingleScenario(arguments: [String]) {
        let options = parseOptions(arguments)

        let text = options["--text"] ?? "hello"

        guard let copyToClipboard = parseBool(options["--copy"]) else {
            fail("Missing/invalid --copy (true|false)")
        }
        guard let directInsertSucceeded = parseBool(options["--direct"]) else {
            fail("Missing/invalid --direct (true|false)")
        }
        guard let typingInsertSucceeded = parseBool(options["--typing"]) else {
            fail("Missing/invalid --typing (true|false)")
        }
        guard let specialPasteSucceeded = parseBool(options["--special"]) else {
            fail("Missing/invalid --special (true|false)")
        }

        let decision = InsertionDecisionModel.evaluate(
            text: text,
            copyToClipboard: copyToClipboard,
            directInsertSucceeded: directInsertSucceeded,
            typingInsertSucceeded: typingInsertSucceeded,
            specialPasteSucceeded: specialPasteSucceeded
        )

        if let expectedPathRaw = options["--expect-path"] {
            guard let expectedPath = InsertionPath(rawValue: expectedPathRaw) else {
                fail("Unknown --expect-path '\(expectedPathRaw)'")
            }
            check(decision.path == expectedPath, "Expected path \(expectedPath.rawValue), got \(decision.path.rawValue)")
        }

        if let expectedResultRaw = options["--expect-result"] {
            guard let expectedResult = TextInserter.Result(rawValue: expectedResultRaw) else {
                fail("Unknown --expect-result '\(expectedResultRaw)'")
            }
            check(decision.result == expectedResult, "Expected result \(expectedResult.rawValue), got \(decision.result.rawValue)")
        }

        print("path=\(decision.path.rawValue) result=\(decision.result.rawValue)")
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                fail("Unexpected argument '\(key)'. Use --help for usage.")
            }

            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                fail("Missing value for option '\(key)'")
            }

            options[key] = arguments[nextIndex]
            index += 2
        }

        return options
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func printUsage() {
        print("""
        InsertionReliabilityRunner

        Usage:
          --regression
            Run built-in matrix of reliability scenarios (default if no args).

          --text <value> --copy <bool> --direct <bool> --typing <bool> --special <bool>
            Simulate one scenario.

          Optional assertions:
            --expect-path <empty-input|direct-accessibility|typed-unicode-events|special-paste-clipboard|special-paste-transient-clipboard>
            --expect-result <empty|pasted|copied-only|not-inserted>

        Example:
          /tmp/openassist-insertion-reliability \
            --text hello --copy true --direct false --typing false --special false \
            --expect-path special-paste-clipboard --expect-result copied-only
        """)
    }
}
