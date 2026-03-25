import AppKit
import XCTest
@testable import OpenAssist

final class AssistantComputerUseServiceTests: XCTestCase {
    func testParseRequestRejectsMissingReason() {
        XCTAssertThrowsError(
            try AssistantComputerUseService.parseRequest(
                from: [
                    "task": "Click the Filters button.",
                    "action": ["type": "click", "x": 10, "y": 20]
                ]
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Computer Use needs a reason.")
        }
    }

    func testCoordinateActionRequiresObserveFirst() async {
        let service = AssistantComputerUseService(
            helper: .shared,
            frontmostAppProvider: {
                AssistantComputerUseFrontmostAppContext(
                    bundleIdentifier: "com.example.dashboard",
                    displayName: "Dashboard"
                )
            }
        )

        let result = await service.run(
            sessionID: "thread-1",
            arguments: [
                "task": "Click the Filters button.",
                "reason": "Need generic UI interaction.",
                "action": ["type": "click", "x": 10, "y": 20]
            ],
            preferredModelID: nil
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.summary.contains("observe action first"))
        XCTAssertFalse(result.contentItems.contains(where: { $0.type == "inputImage" }))
    }

    func testObserveThenClickReusesSessionScreenshotAndReturnsFreshImage() async {
        let actionLog = LockedComputerUseActionLog()
        let frontmostBox = LockedFrontmostAppBox(
            AssistantComputerUseFrontmostAppContext(
                bundleIdentifier: "com.example.dashboard",
                displayName: "Dashboard"
            )
        )
        let snapshots = [
            makeSnapshot(token: "observe"),
            makeSnapshot(token: "click")
        ]

        let service = AssistantComputerUseService(
            executeActions: { actions, previousSnapshot in
                actionLog.append(actions: actions, previousSnapshot: previousSnapshot)
                let index = actionLog.callCount - 1
                return snapshots[index]
            },
            frontmostAppProvider: {
                frontmostBox.value
            }
        )

        let observeResult = await service.run(
            sessionID: "thread-1",
            arguments: [
                "task": "Observe the current dashboard.",
                "reason": "Need the latest screenshot before clicking.",
                "action": ["type": "observe"]
            ],
            preferredModelID: nil
        )
        XCTAssertTrue(observeResult.success)
        XCTAssertTrue(observeResult.summary.contains("Observed the current screen"))
        XCTAssertTrue(observeResult.contentItems.contains(where: { $0.type == "inputImage" }))

        let clickResult = await service.run(
            sessionID: "thread-1",
            arguments: [
                "task": "Click the Filters button.",
                "reason": "Need generic UI interaction.",
                "targetLabel": "Filters button",
                "action": ["type": "click", "x": 24, "y": 12]
            ],
            preferredModelID: nil
        )

        XCTAssertTrue(clickResult.success)
        XCTAssertTrue(clickResult.summary.contains("Clicked at"))
        XCTAssertTrue(clickResult.summary.contains("Screenshot size"))
        XCTAssertEqual(actionLog.callCount, 2)
        XCTAssertEqual(actionLog.actions[safe: 0]?.first?["type"] as? String, "observe")
        XCTAssertEqual(actionLog.actions[safe: 1]?.first?["type"] as? String, "click")
        XCTAssertNil(actionLog.previousSnapshots[safe: 0] ?? nil)
        XCTAssertEqual(
            (actionLog.previousSnapshots[safe: 1] ?? nil)?.imageDataURL,
            snapshots[0].imageDataURL
        )
    }

    func testChangingFrontmostAppRequiresFreshObserveBeforeCoordinateAction() async {
        let frontmostBox = LockedFrontmostAppBox(
            AssistantComputerUseFrontmostAppContext(
                bundleIdentifier: "com.example.one",
                displayName: "App One"
            )
        )
        let service = AssistantComputerUseService(
            executeActions: { _, _ in
                self.makeSnapshot(token: UUID().uuidString)
            },
            frontmostAppProvider: {
                frontmostBox.value
            }
        )

        _ = await service.run(
            sessionID: "thread-1",
            arguments: [
                "task": "Observe App One.",
                "reason": "Need a baseline screenshot.",
                "action": ["type": "observe"]
            ],
            preferredModelID: nil
        )

        frontmostBox.value = AssistantComputerUseFrontmostAppContext(
            bundleIdentifier: "com.example.two",
            displayName: "App Two"
        )

        let result = await service.run(
            sessionID: "thread-1",
            arguments: [
                "task": "Click the primary button.",
                "reason": "Need generic UI interaction.",
                "action": ["type": "click", "x": 40, "y": 40]
            ],
            preferredModelID: nil
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.summary.contains("frontmost app changed"))
        XCTAssertTrue(result.contentItems.contains(where: { $0.type == "inputImage" }))
    }

    func testTypingSecretsIsRejected() async {
        let service = AssistantComputerUseService(
            executeActions: { _, _ in
                XCTFail("Computer Use should not execute secret entry.")
                return self.makeSnapshot(token: "unexpected")
            },
            frontmostAppProvider: {
                AssistantComputerUseFrontmostAppContext(
                    bundleIdentifier: "com.example.login",
                    displayName: "Login Window"
                )
            }
        )

        let result = await service.run(
            sessionID: "thread-1",
            arguments: [
                "task": "Type the password into the login form.",
                "reason": "Need to finish sign-in.",
                "targetLabel": "Password field",
                "action": ["type": "type", "text": "hunter2"]
            ],
            preferredModelID: nil
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.summary.contains("will not type passwords"))
    }

    private func makeSnapshot(token: String) -> LocalAutomationDisplaySnapshot {
        let width = 100
        let height = 60
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return LocalAutomationDisplaySnapshot(
            image: image,
            imageSize: CGSize(width: width, height: height),
            screenFrame: CGRect(x: 0, y: 0, width: width, height: height),
            imageDataURL: "data:image/png;base64,\(Data(token.utf8).base64EncodedString())"
        )
    }
}

private final class LockedComputerUseActionLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var actions: [[[String: Any]]] = []
    private(set) var previousSnapshots: [LocalAutomationDisplaySnapshot?] = []

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }

    func append(actions: [[String: Any]], previousSnapshot: LocalAutomationDisplaySnapshot?) {
        lock.lock()
        self.actions.append(actions)
        previousSnapshots.append(previousSnapshot)
        lock.unlock()
    }
}

private final class LockedFrontmostAppBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: AssistantComputerUseFrontmostAppContext

    init(_ value: AssistantComputerUseFrontmostAppContext) {
        storedValue = value
    }

    var value: AssistantComputerUseFrontmostAppContext {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
