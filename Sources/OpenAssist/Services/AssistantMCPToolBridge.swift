import Foundation
import Network

protocol AssistantMCPToolBridgeDelegate: AnyObject, Sendable {
    func mcpBridgeExecute(
        toolName: String,
        arguments: Any,
        sessionID: String
    ) async -> AssistantToolExecutionResult
}

actor AssistantMCPToolBridge {
    private let queue = DispatchQueue(label: "OpenAssist.MCPToolBridge")
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private weak var delegate: (any AssistantMCPToolBridgeDelegate)?
    private var activeSessionID: String = ""

    private(set) var port: UInt16?

    init(delegate: (any AssistantMCPToolBridgeDelegate)? = nil) {
        self.delegate = delegate
    }

    func setDelegate(_ delegate: any AssistantMCPToolBridgeDelegate) {
        self.delegate = delegate
    }

    func setActiveSessionID(_ sessionID: String) {
        self.activeSessionID = sessionID
    }

    // MARK: - Lifecycle

    func start() throws {
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let newListener = try NWListener(using: parameters)
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                let resolvedPort = newListener.port?.rawValue
                Task { await self.didResolvePort(resolvedPort) }
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleNewConnection(connection) }
        }
        self.listener = newListener
        newListener.start(queue: queue)
    }

    func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - Connection Handling

    private func didResolvePort(_ resolvedPort: UInt16?) {
        self.port = resolvedPort
    }

    private func handleNewConnection(_ connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection
        connection.start(queue: queue)
        receiveData(on: connection)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.handleReceivedData(data, on: connection)
                }
                if isComplete || error != nil {
                    await self.connectionClosed(connection)
                } else {
                    await self.receiveData(on: connection)
                }
            }
        }
    }

    private func connectionClosed(_ connection: NWConnection) {
        if activeConnection === connection {
            activeConnection = nil
        }
    }

    // MARK: - Request Processing

    private func handleReceivedData(_ data: Data, on connection: NWConnection) async {
        // Split by newlines -- each line is a JSON-RPC message
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            guard let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let method = request["method"] as? String else {
                continue
            }
            let params = request["params"] as? [String: Any] ?? [:]
            let response = await processRequest(method: method, params: params)
            // Send response back with request ID
            var responseDict = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] ?? [:]
            if let id = request["id"] {
                responseDict["id"] = id
            }
            if let responseData = try? JSONSerialization.data(withJSONObject: responseDict) {
                let framedData = responseData + Data("\n".utf8)
                connection.send(content: framedData, completion: .contentProcessed { _ in })
            }
        }
    }

    private func processRequest(method: String, params: [String: Any]) async -> Data {
        switch method {
        case "tools/call":
            return await handleToolCall(params: params)
        default:
            return MCPProtocol.errorResponse(id: nil, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleToolCall(params: [String: Any]) async -> Data {
        guard let toolName = params["name"] as? String else {
            return MCPProtocol.response(id: nil, result: MCPProtocol.toolCallError(message: "Missing tool name"))
        }
        let arguments = params["arguments"] ?? [String: Any]()

        guard let delegate else {
            return MCPProtocol.response(id: nil, result: MCPProtocol.toolCallError(message: "Bridge delegate not available"))
        }

        let result = await delegate.mcpBridgeExecute(
            toolName: toolName,
            arguments: arguments,
            sessionID: activeSessionID
        )

        return MCPProtocol.response(id: nil, result: MCPProtocol.toolCallResult(from: result))
    }
}
