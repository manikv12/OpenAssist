import Foundation

enum RemoteTunnelMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case disabled
    case quick
    case named

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .quick:
            return "Quick Tunnel"
        case .named:
            return "Named Tunnel"
        }
    }
}

enum RemoteTunnelTransport: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case quic
    case http2

    var id: String { rawValue }
}

enum RemoteAccessActionType: String, Codable, CaseIterable, Sendable {
    case selectSession
    case newSession
    case sendPrompt
    case stopTurn
    case chooseModel
    case chooseBackend
    case setMode
    case setReasoningEffort
    case applyPlugins
    case resolvePermission
    case cancelPermission
    case deleteSession
}

enum RemoteAccessEventType: String, Codable, Sendable {
    case snapshot
    case sessionUpdated
    case permissionUpdated
    case statusChanged
}

enum RemoteAccessJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RemoteAccessJSONValue])
    case array([RemoteAccessJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: RemoteAccessJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([RemoteAccessJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct RemoteAccessMachine: Codable, Equatable, Sendable {
    let machineID: String
    let displayName: String
    let hostName: String
    let appVersion: String
    let operatingSystem: String
    let localBaseURL: String
    let publicBaseURL: String?
}

struct RemoteAccessTunnelStatus: Codable, Equatable, Sendable {
    let mode: RemoteTunnelMode
    let transport: RemoteTunnelTransport
    let configured: Bool
    let isRunning: Bool
    let publicURL: String?
    let warning: String?
    let detail: String?
    let executablePath: String?
}

struct RemoteAccessControlState: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    let deviceID: String
    let deviceName: String
    let acquiredAt: Date
    let activeTurnID: String?

    var id: String { sessionID }
}

struct RemoteAccessUsageWindow: Codable, Equatable, Sendable {
    let label: String
    let usedPercent: Int
    let resetsAt: Date?
    let resetsInLabel: String?
}

struct RemoteAccessContextUsage: Codable, Equatable, Sendable {
    let usedPercent: Int
    let summary: String
    let detail: String?
}

struct RemoteAccessUsage: Codable, Equatable, Sendable {
    let providerBackend: String
    let providerLabel: String
    let planType: String?
    let primary: RemoteAccessUsageWindow?
    let secondary: RemoteAccessUsageWindow?
    let context: RemoteAccessContextUsage?
}

struct RemoteAccessStatus: Codable, Equatable, Sendable {
    let runtimeAvailability: String
    let runtimeSummary: String
    let runtimeDetail: String?
    let helperState: String
    let helperMessage: String?
    let tunnel: RemoteAccessTunnelStatus
    let usage: RemoteAccessUsage?
}

struct RemoteAccessPairedDevice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let createdAt: Date
    let lastSeenAt: Date?
    let userAgent: String?
    let isCurrent: Bool
}

struct RemoteAccessBackendOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

struct RemoteAccessModelOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let inputModalities: [String]
    let supportedReasoningEfforts: [String]
}

struct RemoteAccessPlugin: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let summary: String?
    let needsSetup: Bool
    let iconDataURL: String?
}

struct RemoteAccessSession: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String?
    let projectID: String?
    let projectName: String?
    let backend: String?
    let modelID: String?
    let interactionMode: String?
    let reasoningEffort: String?
    let isTemporary: Bool
    let hasActiveTurn: Bool
    let updatedAt: Date?
}

struct RemoteAccessTranscriptEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let role: String
    let text: String
    let createdAt: Date
    let isStreaming: Bool
    let providerBackend: String?
    let providerModelID: String?
    let selectedPluginIDs: [String]
}

struct RemoteAccessToolCall: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: String
    let detail: String?
}

struct RemoteAccessPermissionOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: String?
    let isDefault: Bool
}

struct RemoteAccessPermissionQuestionOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let detail: String?
}

struct RemoteAccessPermissionQuestion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let header: String
    let prompt: String
    let allowsCustomAnswer: Bool
    let options: [RemoteAccessPermissionQuestionOption]
}

struct RemoteAccessPermissionRequest: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let toolTitle: String
    let toolKind: String?
    let rationale: String?
    let rawPayloadSummary: String?
    let requiresDesktopAppConfirmation: Bool
    let options: [RemoteAccessPermissionOption]
    let questions: [RemoteAccessPermissionQuestion]
}

struct RemoteAccessSessionDetail: Codable, Equatable, Sendable {
    let session: RemoteAccessSession
    let transcript: [RemoteAccessTranscriptEntry]
    let activeToolCalls: [RemoteAccessToolCall]
    let recentToolCalls: [RemoteAccessToolCall]
    let pendingPermission: RemoteAccessPermissionRequest?
    let selectedPluginIDs: [String]
    let pendingOutgoingMessage: String?
    let activeTurnID: String?
    let awaitingAssistantStart: Bool
    let queuedPromptCount: Int
}

struct RemoteAccessProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let parentID: String?
    let sessionCount: Int
}

struct RemoteAccessSnapshot: Codable, Equatable, Sendable {
    let machine: RemoteAccessMachine
    let status: RemoteAccessStatus
    let pairedDevice: RemoteAccessPairedDevice?
    let sessions: [RemoteAccessSession]
    let selectedSessionID: String?
    let selectedSession: RemoteAccessSessionDetail?
    let remoteControl: RemoteAccessControlState?
    let availableBackends: [RemoteAccessBackendOption]
    let availableModels: [RemoteAccessModelOption]
    let installedPlugins: [RemoteAccessPlugin]
    let projects: [RemoteAccessProject]
}

struct RemoteAccessEvent: Codable, Equatable, Sendable {
    let sequence: Int
    let type: RemoteAccessEventType
    let snapshot: RemoteAccessSnapshot?
}

struct RemoteAccessActionRequest: Codable, Equatable, Sendable {
    let id: String
    let machineID: String?
    let type: RemoteAccessActionType
    let sessionID: String?
    let payload: RemoteAccessJSONValue?
}

struct RemoteAccessActionResponse: Codable, Equatable, Sendable {
    let id: String
    let ok: Bool
    let snapshot: RemoteAccessSnapshot?
    let error: String?
}

struct RemoteAccessPairClaimRequest: Codable, Equatable, Sendable {
    let code: String?
    let deviceName: String?
    let adminPassword: String?
}

struct RemoteAccessPairClaimResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let machineID: String?
    let deviceToken: String?
    let snapshot: RemoteAccessSnapshot?
    let error: String?
}

struct RemoteAccessHealthResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let helperState: String
    let helperMessage: String?
    let machineID: String
    let machineName: String
    let appVersion: String
    let localBaseURL: String
    let publicBaseURL: String?
    let tunnelMode: String
    let adminPasswordRequired: Bool
}

struct RemoteAccessPairedDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let tokenHash: String
    let createdAt: Date
    var lastSeenAt: Date?
    let userAgent: String?
}

struct RemoteAccessPairingChallenge: Codable, Equatable, Sendable {
    let code: String
    let expiresAt: Date
    let createdAt: Date
    let suggestedURL: String?
}
