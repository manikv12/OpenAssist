import Foundation

enum LocalAutomationConnectorKind: String, CaseIterable, Codable, Sendable {
    case browser
    case app
}

struct ConnectorDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let kind: LocalAutomationConnectorKind
    let supportedActions: [String]
}

struct LocalAutomationPermissionSnapshot: Codable, Equatable, Sendable {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let appleEventsGranted: Bool
    let appleEventsKnown: Bool
    let fullDiskAccessGranted: Bool
    let fullDiskAccessKnown: Bool
}

struct HelperCapabilityStatus: Codable, Equatable, Sendable {
    let helperName: String
    let available: Bool
    let executionMode: String
    let permissions: LocalAutomationPermissionSnapshot
    let connectors: [ConnectorDescriptor]
    let supportedBrowsers: [String]
    let selectedBrowserProfileLabel: String?
    let issues: [String]
}

struct ConnectorActionRequest: Codable, Equatable, Sendable {
    let toolName: String
    let task: String
    let app: String?
    let action: String?
    let target: String?
    let url: String?
    let command: String?
    let title: String?
    let notes: String?
    let pane: String?
    let startISO8601: String?
    let endISO8601: String?
    let browserProfileID: String?
    let commit: Bool
}

struct ConnectorActionResult: Codable, Equatable, Sendable {
    let success: Bool
    let summary: String
    let details: String?
    let connectorID: String
    let requiresConfirmation: Bool
    let confirmationMessage: String?
}
