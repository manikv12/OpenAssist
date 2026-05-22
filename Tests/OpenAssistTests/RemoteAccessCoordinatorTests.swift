import Foundation
import XCTest
@preconcurrency @testable import OpenAssist

@MainActor
final class RemoteAccessCoordinatorTests: XCTestCase {
    func testNamedTunnelPublicURLDefaultsToUserConfiguredBlankValue() {
        let coordinator = RemoteAccessCoordinator(
            defaults: makeDefaults(),
            bridge: TestRemoteAccessBridge(),
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )

        XCTAssertEqual(coordinator.namedTunnelName, "openassist")
        XCTAssertEqual(coordinator.namedTunnelPublicURL, "")
    }

    func testPairClaimSucceedsOnceAndReturnsDeviceToken() async throws {
        let defaults = makeDefaults()
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: TestRemoteAccessBridge(),
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        coordinator.installPairingChallenge(
            RemoteAccessPairingChallenge(
                code: "pair-code",
                expiresAt: Date().addingTimeInterval(60),
                createdAt: Date(),
                suggestedURL: nil
            )
        )

        let response = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json", "user-agent": "Mozilla/5.0 (iPhone)"],
                    body: RemoteAccessPairClaimRequest(code: "pair-code", deviceName: "My iPhone", adminPassword: nil)
                )
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.machineID, coordinator.machineID)
        XCTAssertNotNil(response.deviceToken)
        XCTAssertEqual(response.snapshot?.pairedDevice?.name, "My iPhone")

        let secondResponse = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(code: "pair-code", deviceName: "My iPhone", adminPassword: nil)
                )
            )
        )

        XCTAssertFalse(secondResponse.ok)
        XCTAssertEqual(secondResponse.error, "There is no active pairing code.")
    }

    func testPairClaimRejectsExpiredCodes() async throws {
        let defaults = makeDefaults()
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: TestRemoteAccessBridge(),
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        coordinator.installPairingChallenge(
            RemoteAccessPairingChallenge(
                code: "expired-code",
                expiresAt: Date().addingTimeInterval(-30),
                createdAt: Date().addingTimeInterval(-60),
                suggestedURL: nil
            )
        )

        let response = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(code: "expired-code", deviceName: "Safari", adminPassword: nil)
                )
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "That pairing code has expired.")
    }

    func testPairClaimRequiresAdminPasswordWhenConfigured() async throws {
        let defaults = makeDefaults()
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: TestRemoteAccessBridge(),
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        XCTAssertTrue(coordinator.setAdminPassword("correct horse"))
        coordinator.installPairingChallenge(
            RemoteAccessPairingChallenge(
                code: "pair-password",
                expiresAt: Date().addingTimeInterval(60),
                createdAt: Date(),
                suggestedURL: nil
            )
        )

        let missingPassword = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(
                        code: "pair-password",
                        deviceName: "Safari",
                        adminPassword: nil
                    )
                )
            )
        )
        XCTAssertFalse(missingPassword.ok)
        XCTAssertEqual(missingPassword.error, "Enter the Remote Access password.")

        let wrongPassword = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(
                        code: "pair-password",
                        deviceName: "Safari",
                        adminPassword: "wrong password"
                    )
                )
            )
        )
        XCTAssertFalse(wrongPassword.ok)
        XCTAssertEqual(wrongPassword.error, "That Remote Access password is incorrect.")

        let accepted = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(
                        code: "pair-password",
                        deviceName: "Safari",
                        adminPassword: "correct horse"
                    )
                )
            )
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertNotNil(accepted.deviceToken)
    }

    func testPairClaimWithAdminPasswordDoesNotRequirePairingCode() async throws {
        let defaults = makeDefaults()
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: TestRemoteAccessBridge(),
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        XCTAssertTrue(coordinator.setAdminPassword("correct horse"))

        let response = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(
                        code: nil,
                        deviceName: "Safari",
                        adminPassword: "correct horse"
                    )
                )
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.machineID, coordinator.machineID)
        XCTAssertNotNil(response.deviceToken)
        XCTAssertEqual(response.snapshot?.pairedDevice?.name, "Safari")
    }

    func testRevokedDeviceCannotAccessState() async throws {
        let defaults = makeDefaults()
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: TestRemoteAccessBridge(),
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        coordinator.installPairingChallenge(
            RemoteAccessPairingChallenge(
                code: "pair-revoke",
                expiresAt: Date().addingTimeInterval(60),
                createdAt: Date(),
                suggestedURL: nil
            )
        )

        let pairResponse = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(code: "pair-revoke", deviceName: "Browser", adminPassword: nil)
                )
            )
        )
        guard let deviceToken = pairResponse.deviceToken,
              let deviceID = pairResponse.snapshot?.pairedDevice?.id else {
            return XCTFail("Expected a paired device and token.")
        }

        let authorizedState = await coordinator.route(
            makeRequest(
                method: "GET",
                path: "/remote/v1/state",
                headers: ["authorization": "Bearer \(deviceToken)"]
            )
        )
        guard case .response(let authorizedResponse) = authorizedState else {
            return XCTFail("Expected a normal HTTP response.")
        }
        XCTAssertEqual(authorizedResponse.statusCode, 200)

        coordinator.revokeDevice(id: deviceID)

        let deniedState = await coordinator.route(
            makeRequest(
                method: "GET",
                path: "/remote/v1/state",
                headers: ["authorization": "Bearer \(deviceToken)"]
            )
        )
        guard case .response(let deniedResponse) = deniedState else {
            return XCTFail("Expected a normal HTTP response.")
        }
        XCTAssertEqual(deniedResponse.statusCode, 401)
    }

    func testRemoteNewSessionForwardsProjectIDAndSelectsCreatedThread() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        bridge.startNewSessionSnapshot = makeSessionSnapshot(
            id: "project-new",
            status: .idle,
            activeTurnID: nil,
            projectID: "project-1",
            projectName: "OpenAssist"
        )
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let token = try await pairDevice(
            named: "Project Phone",
            code: "pair-project-new",
            coordinator: coordinator
        )

        let response = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(token)"],
                    body: RemoteAccessActionRequest(
                        id: "new-project-1",
                        machineID: coordinator.machineID,
                        type: .newSession,
                        sessionID: nil,
                        payload: .object([
                            "temporary": .bool(false),
                            "projectID": .string("project-1")
                        ])
                    )
                )
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.snapshot?.selectedSessionID, "project-new")
        XCTAssertEqual(response.snapshot?.selectedSession?.session.projectID, "project-1")
        XCTAssertEqual(bridge.startNewSessionRequests.count, 1)
        XCTAssertEqual(bridge.startNewSessionRequests.first?.projectID, "project-1")
        XCTAssertTrue(bridge.startNewSessionRequests.first?.preserveVisibleSelection ?? false)
    }

    func testRemoteNewSessionReportsFailureWhenBridgeCannotCreateThread() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let token = try await pairDevice(
            named: "Project Phone",
            code: "pair-project-fail",
            coordinator: coordinator
        )

        let response = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(token)"],
                    body: RemoteAccessActionRequest(
                        id: "new-project-fail",
                        machineID: coordinator.machineID,
                        type: .newSession,
                        sessionID: nil,
                        payload: .object([
                            "temporary": .bool(false),
                            "projectID": .string("project-1")
                        ])
                    )
                )
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "Could not start a new chat.")
        XCTAssertNil(response.snapshot)
        XCTAssertEqual(bridge.startNewSessionRequests.first?.projectID, "project-1")
    }

    func testRemoteSelectSessionDoesNotOpenSessionOnMac() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        bridge.snapshotsByID["session-remote"] = makeSessionSnapshot(
            id: "session-remote",
            status: .idle,
            activeTurnID: nil
        )
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let token = try await pairDevice(
            named: "Remote iPhone",
            code: "pair-select",
            coordinator: coordinator
        )

        let response = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(token)"],
                    body: RemoteAccessActionRequest(
                        id: "select-remote",
                        machineID: coordinator.machineID,
                        type: .selectSession,
                        sessionID: "session-remote",
                        payload: nil
                    )
                )
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.snapshot?.selectedSessionID, "session-remote")
        XCTAssertEqual(response.snapshot?.selectedSession?.session.id, "session-remote")
        XCTAssertNil(bridge.selectedSessionID)
        XCTAssertTrue(bridge.openSessionRequests.isEmpty)
    }

    func testRemoteSendPromptClaimsControlForActiveTurn() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        bridge.sendPromptSnapshot = makeSessionSnapshot(
            id: "session-remote",
            status: .active,
            activeTurnID: "turn-remote"
        )
        bridge.snapshotsByID["session-remote"] = bridge.sendPromptSnapshot
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let token = try await pairDevice(
            named: "Remote iPhone",
            code: "pair-remote",
            coordinator: coordinator
        )

        let response = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(token)"],
                    body: RemoteAccessActionRequest(
                        id: "send-1",
                        machineID: coordinator.machineID,
                        type: .sendPrompt,
                        sessionID: "session-remote",
                        payload: .object([
                            "prompt": .string("Work from remote")
                        ])
                    )
                )
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.snapshot?.remoteControl?.sessionID, "session-remote")
        XCTAssertEqual(response.snapshot?.remoteControl?.deviceName, "Remote iPhone")
        XCTAssertEqual(response.snapshot?.remoteControl?.activeTurnID, "turn-remote")
        XCTAssertTrue(coordinator.isSessionRemoteControlled("session-remote"))
    }

    func testDifferentRemoteDeviceIsBlockedUntilMacTakesOver() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        bridge.sendPromptSnapshot = makeSessionSnapshot(
            id: "session-remote",
            status: .active,
            activeTurnID: "turn-remote"
        )
        bridge.snapshotsByID["session-remote"] = bridge.sendPromptSnapshot
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let ownerToken = try await pairDevice(
            named: "Remote iPhone",
            code: "pair-owner",
            coordinator: coordinator
        )
        let otherToken = try await pairDevice(
            named: "Remote iPad",
            code: "pair-other",
            coordinator: coordinator
        )

        _ = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(ownerToken)"],
                    body: RemoteAccessActionRequest(
                        id: "send-1",
                        machineID: coordinator.machineID,
                        type: .sendPrompt,
                        sessionID: "session-remote",
                        payload: .object(["prompt": .string("Start work")])
                    )
                )
            )
        )

        let blockedResponse = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(otherToken)"],
                    body: RemoteAccessActionRequest(
                        id: "stop-blocked",
                        machineID: coordinator.machineID,
                        type: .stopTurn,
                        sessionID: "session-remote",
                        payload: nil
                    )
                )
            )
        )
        XCTAssertFalse(blockedResponse.ok)
        XCTAssertEqual(blockedResponse.error, "This thread is being controlled from Remote iPhone.")

        coordinator.takeOverSession("session-remote")
        let allowedResponse = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(otherToken)"],
                    body: RemoteAccessActionRequest(
                        id: "stop-allowed",
                        machineID: coordinator.machineID,
                        type: .stopTurn,
                        sessionID: "session-remote",
                        payload: nil
                    )
                )
            )
        )

        XCTAssertTrue(allowedResponse.ok)
        XCTAssertEqual(bridge.cancelledSessionIDs, ["session-remote"])
    }

    func testRemoteControlReleasesWhenRemoteTurnFinishes() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        bridge.sendPromptSnapshot = makeSessionSnapshot(
            id: "session-remote",
            status: .active,
            activeTurnID: "turn-remote"
        )
        bridge.snapshotsByID["session-remote"] = bridge.sendPromptSnapshot
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let token = try await pairDevice(
            named: "Remote iPhone",
            code: "pair-release",
            coordinator: coordinator
        )

        _ = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(token)"],
                    body: RemoteAccessActionRequest(
                        id: "send-1",
                        machineID: coordinator.machineID,
                        type: .sendPrompt,
                        sessionID: "session-remote",
                        payload: .object(["prompt": .string("Start work")])
                    )
                )
            )
        )
        XCTAssertTrue(coordinator.isSessionRemoteControlled("session-remote"))

        bridge.snapshotsByID["session-remote"] = makeSessionSnapshot(
            id: "session-remote",
            status: .completed,
            activeTurnID: nil
        )
        let state = try await decodeResponse(
            RemoteAccessSnapshot.self,
            from: coordinator.route(
                makeRequest(
                    method: "GET",
                    path: "/remote/v1/state",
                    headers: ["authorization": "Bearer \(token)"]
                )
            )
        )

        XCTAssertNil(state.remoteControl)
        XCTAssertFalse(coordinator.isSessionRemoteControlled("session-remote"))
    }

    func testRemoteDeleteSessionArchivesInsteadOfDeletingArtifacts() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        bridge.snapshotsByID["session-archive"] = makeSessionSnapshot(
            id: "session-archive",
            status: .idle,
            activeTurnID: nil
        )
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let token = try await pairDevice(
            named: "Remote Browser",
            code: "pair-archive",
            coordinator: coordinator
        )

        let response = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(token)"],
                    body: RemoteAccessActionRequest(
                        id: "archive-1",
                        machineID: coordinator.machineID,
                        type: .deleteSession,
                        sessionID: "session-archive",
                        payload: nil
                    )
                )
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(bridge.archivedSessionIDs, ["session-archive"])
        XCTAssertTrue(bridge.deletedSessionIDs.isEmpty)
    }

    func testChooseBackendTargetsRequestedSession() async throws {
        let defaults = makeDefaults()
        let bridge = TestRemoteAccessBridge()
        bridge.snapshotsByID["session-remote"] = makeSessionSnapshot(
            id: "session-remote",
            status: .idle,
            activeTurnID: nil
        )
        let coordinator = RemoteAccessCoordinator(
            defaults: defaults,
            bridge: bridge,
            tunnelProvider: TestTunnelProvider(),
            secretStore: TestRemoteAccessSecretStore()
        )
        let token = try await pairDevice(
            named: "Remote Browser",
            code: "pair-backend",
            coordinator: coordinator
        )

        let response = try await decodeResponse(
            RemoteAccessActionResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/actions",
                    headers: ["authorization": "Bearer \(token)"],
                    body: RemoteAccessActionRequest(
                        id: "backend-1",
                        machineID: coordinator.machineID,
                        type: .chooseBackend,
                        sessionID: "session-remote",
                        payload: .object(["backend": .string(AssistantRuntimeBackend.copilot.rawValue)])
                    )
                )
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(bridge.selectedBackendRequests.count, 1)
        XCTAssertEqual(bridge.selectedBackendRequests.first?.backend, .copilot)
        XCTAssertEqual(bridge.selectedBackendRequests.first?.sessionID, "session-remote")
    }

    func testActionRequestDecodesTypedPayload() throws {
        let requestData = try makeJSONData(
            RemoteAccessActionRequest(
                id: "action-1",
                machineID: "machine-1",
                type: .sendPrompt,
                sessionID: "session-1",
                payload: .object([
                    "prompt": .string("Hello"),
                    "selectedPluginIDs": .array([.string("plugin-a"), .string("plugin-b")])
                ])
            )
        )

        let decoded = try JSONDecoder().decode(RemoteAccessActionRequest.self, from: requestData)
        XCTAssertEqual(decoded.type, .sendPrompt)
        XCTAssertEqual(decoded.machineID, "machine-1")
        guard case .object(let payload)? = decoded.payload else {
            return XCTFail("Expected an object payload.")
        }
        guard case .string(let prompt)? = payload["prompt"] else {
            return XCTFail("Expected a string prompt.")
        }
        guard case .array(let pluginValues)? = payload["selectedPluginIDs"] else {
            return XCTFail("Expected a plugin array.")
        }
        XCTAssertEqual(prompt, "Hello")
        XCTAssertEqual(
            pluginValues.compactMap { value in
                if case .string(let stringValue) = value {
                    return stringValue
                }
                return nil
            },
            ["plugin-a", "plugin-b"]
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteAccessCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "OpenAssist.remoteAccess.enabled")
        return defaults
    }

    private func makeRequest<Body: Encodable>(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Body? = nil
    ) -> AutomationAPIHTTPRequest {
        let bodyData = (try? body.map(makeJSONData(_:))) ?? Data()
        return AutomationAPIHTTPRequest(
            method: method,
            target: path,
            path: path,
            headers: headers,
            body: bodyData
        )
    }

    private func makeRequest(
        method: String,
        path: String,
        headers: [String: String] = [:]
    ) -> AutomationAPIHTTPRequest {
        AutomationAPIHTTPRequest(
            method: method,
            target: path,
            path: path,
            headers: headers,
            body: Data()
        )
    }

    private func makeJSONData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func decodeResponse<T: Decodable>(
        _ type: T.Type,
        from result: RemoteAccessServerResult
    ) async throws -> T {
        guard case .response(let response) = result else {
            throw XCTSkip("Expected an HTTP response.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: response.body)
    }

    private func pairDevice(
        named deviceName: String,
        code: String,
        coordinator: RemoteAccessCoordinator
    ) async throws -> String {
        coordinator.installPairingChallenge(
            RemoteAccessPairingChallenge(
                code: code,
                expiresAt: Date().addingTimeInterval(60),
                createdAt: Date(),
                suggestedURL: nil
            )
        )
        let response = try await decodeResponse(
            RemoteAccessPairClaimResponse.self,
            from: coordinator.route(
                makeRequest(
                    method: "POST",
                    path: "/remote/v1/pair/claim",
                    headers: ["content-type": "application/json"],
                    body: RemoteAccessPairClaimRequest(code: code, deviceName: deviceName, adminPassword: nil)
                )
            )
        )
        guard let token = response.deviceToken else {
            throw XCTSkip("Expected a device token.")
        }
        return token
    }

    private func makeSessionSnapshot(
        id: String,
        status: AssistantSessionStatus,
        activeTurnID: String?,
        projectID: String? = nil,
        projectName: String? = nil
    ) -> AssistantRemoteSessionSnapshot {
        var session = AssistantSessionSummary(
            id: id,
            title: "Remote Thread",
            source: .openAssist,
            status: status,
            updatedAt: Date()
        )
        session.projectID = projectID
        session.projectName = projectName

        return AssistantRemoteSessionSnapshot(
            session: session,
            transcriptEntries: [],
            pendingPermissionRequest: nil,
            hudState: nil,
            hasActiveTurn: status == .active,
            toolCalls: [],
            recentToolCalls: [],
            imageDelivery: nil,
            activeTurnID: activeTurnID
        )
    }
}

private final class TestTunnelProvider: RemoteTunnelProvider {
    var onStatusChange: (@Sendable (RemoteAccessTunnelStatus) -> Void)?

    func apply(configuration: RemoteTunnelConfiguration) {
        onStatusChange?(
            RemoteAccessTunnelStatus(
                mode: configuration.mode,
                transport: configuration.transport,
                configured: configuration.mode != .disabled,
                isRunning: false,
                publicURL: nil,
                warning: nil,
                detail: "Test tunnel provider",
                executablePath: configuration.manualExecutablePath.nonEmpty
            )
        )
    }

    func stop() {}
}

private final class TestRemoteAccessSecretStore: RemoteAccessSecretStore {
    private var values: [String: String] = [:]

    func load(account: String) -> String {
        values[account] ?? ""
    }

    func store(_ value: String, account: String) {
        values[account] = value
    }

    func delete(account: String) {
        values.removeValue(forKey: account)
    }
}

@MainActor
private final class TestRemoteAccessBridge: RemoteAccessBridge {
    var selectedSessionID: String?
    var snapshotsByID: [String: AssistantRemoteSessionSnapshot] = [:]
    var sendPromptSnapshot: AssistantRemoteSessionSnapshot?
    var cancelledSessionIDs: [String?] = []
    var archivedSessionIDs: [String] = []
    var deletedSessionIDs: [String] = []
    var selectedBackendRequests: [(backend: AssistantRuntimeBackend, sessionID: String?)] = []
    var startNewSessionSnapshot: AssistantRemoteSessionSnapshot?
    var startNewTemporarySessionSnapshot: AssistantRemoteSessionSnapshot?
    var startNewSessionRequests: [(projectID: String?, preserveVisibleSelection: Bool)] = []
    var startNewTemporarySessionRequests: [(projectID: String?, preserveVisibleSelection: Bool)] = []
    var openSessionRequests: [(sessionID: String, preserveVisibleSelection: Bool)] = []

    func prime() async {}

    func statusSnapshot() -> AssistantRemoteStatusSnapshot {
        AssistantRemoteStatusSnapshot(
            runtimeHealth: .idle,
            assistantBackend: .codex,
            selectedSessionID: selectedSessionID,
            selectedSessionTitle: nil,
            selectedSessionIsTemporary: false,
            selectedModelID: nil,
            selectedModelSummary: "Codex",
            interactionMode: .agentic,
            reasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high],
            canAdjustReasoningEffort: true,
            fastModeEnabled: false,
            tokenUsage: .empty,
            rateLimits: .empty,
            lastStatusMessage: nil
        )
    }

    func listSessions(
        limit: Int,
        projectID: String?,
        selectedSessionID: String?
    ) async -> [AssistantSessionSummary] {
        Array(snapshotsByID.values.map(\.session).prefix(limit))
    }

    func availableModels() async -> [AssistantModelOption] {
        []
    }

    func availableBackends() -> [AssistantRuntimeBackend] {
        [.codex, .copilot]
    }

    func selectBackend(
        _ backend: AssistantRuntimeBackend,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> Bool {
        selectedBackendRequests.append((backend, sessionID))
        return true
    }

    func openSession(
        sessionID: String,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot? {
        openSessionRequests.append((sessionID, preserveVisibleSelection))
        guard let snapshot = snapshotsByID[sessionID] else { return nil }
        selectedSessionID = sessionID
        return snapshot
    }

    func startNewSession(
        projectID: String?,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot? {
        startNewSessionRequests.append((projectID, preserveVisibleSelection))
        guard let snapshot = startNewSessionSnapshot else { return nil }
        snapshotsByID[snapshot.session.id] = snapshot
        if !preserveVisibleSelection {
            selectedSessionID = snapshot.session.id
        }
        return snapshot
    }

    func startNewTemporarySession(
        projectID: String?,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot? {
        startNewTemporarySessionRequests.append((projectID, preserveVisibleSelection))
        guard let snapshot = startNewTemporarySessionSnapshot else { return nil }
        snapshotsByID[snapshot.session.id] = snapshot
        if !preserveVisibleSelection {
            selectedSessionID = snapshot.session.id
        }
        return snapshot
    }

    func sendPrompt(
        _ prompt: String,
        sessionID: String?,
        projectID: String?,
        selectedPluginIDs: [String],
        oneShotInstructions: String?,
        preserveVisibleSelection: Bool
    ) async -> AssistantRemoteSessionSnapshot? {
        guard let snapshot = sendPromptSnapshot else { return nil }
        snapshotsByID[snapshot.session.id] = snapshot
        if !preserveVisibleSelection {
            selectedSessionID = snapshot.session.id
        }
        return snapshot
    }

    func installedCodexPlugins() async -> [AssistantComposerPluginSelection] {
        []
    }

    func selectedPluginIDs(
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> [String] {
        []
    }

    func applyPlugins(
        _ pluginIDs: [String],
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> Bool {
        true
    }

    func chooseModel(
        _ modelID: String,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async -> Bool {
        true
    }

    func setInteractionMode(
        _ mode: AssistantInteractionMode,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async {}

    func setReasoningEffort(
        _ effort: AssistantReasoningEffort,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async {}

    func sessionSnapshot(
        sessionID: String,
        projectID: String?,
        selectedSessionID: String?
    ) async -> AssistantRemoteSessionSnapshot? {
        snapshotsByID[sessionID]
    }

    func cancelActiveTurn(
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async {
        cancelledSessionIDs.append(sessionID)
    }

    func resolvePermission(
        optionID: String,
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async {}

    func resolvePermission(
        answers: [String: [String]],
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async {}

    func cancelPendingPermissionRequest(
        sessionID: String?,
        preserveVisibleSelection: Bool
    ) async {}

    func archiveSession(sessionID: String) async -> Bool {
        archivedSessionIDs.append(sessionID)
        snapshotsByID.removeValue(forKey: sessionID)
        return true
    }

    func deleteSession(sessionID: String) async -> Bool {
        deletedSessionIDs.append(sessionID)
        return true
    }

    func availableProjects() async -> [AssistantRemoteProjectOption] {
        []
    }
}
