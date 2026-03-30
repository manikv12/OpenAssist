import Foundation
import Network

/// Lightweight MCP stdio server that Copilot and Claude Code spawn as a child process.
/// Handles `initialize` and `tools/list` locally, forwards `tools/call` to the OpenAssist
/// app over a localhost TCP connection.
enum AssistantMCPServerMain {
    private static let bridgeMessageDelimiter = Data("\n".utf8)
    private static let bridgeReceiveChunkSize = 262_144
    private static let bridgeMaximumResponseSize = 50 * 1_048_576

    private final class BridgeReceiveState {
        var buffer = Data()
        var responseData: Data?
    }

    static func run(bridgePort: UInt16) -> Never {
        let toolDescriptors = AssistantToolCatalog.allDescriptors()

        // Read stdin line by line, process each as a JSON-RPC request
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let request = MCPProtocol.JSONRPCRequest(from: data) else {
                continue
            }

            let responseData: Data
            switch request.method {
            case "initialize":
                responseData = MCPProtocol.response(
                    id: request.id,
                    result: MCPProtocol.initializeResult()
                )

            case "notifications/initialized":
                // Client acknowledgement, no response needed
                continue

            case "tools/list":
                responseData = MCPProtocol.response(
                    id: request.id,
                    result: MCPProtocol.toolsListResult(descriptors: toolDescriptors)
                )

            case "tools/call":
                responseData = forwardToolCall(
                    id: request.id,
                    params: request.params,
                    bridgePort: bridgePort
                )

            default:
                responseData = MCPProtocol.errorResponse(
                    id: request.id,
                    code: -32601,
                    message: "Method not found: \(request.method)"
                )
            }

            FileHandle.standardOutput.write(responseData)
        }

        exit(0)
    }

    /// Forward a tools/call request to the OpenAssist bridge over TCP and wait for the response.
    private static func forwardToolCall(
        id: MCPProtocol.JSONRPCRequestID?,
        params: [String: Any],
        bridgePort: UInt16
    ) -> Data {
        let toolName = params["name"] as? String ?? ""
        let arguments = params["arguments"] ?? [String: Any]()

        // Build the bridge request
        var bridgePayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": arguments
            ]
        ]
        if let id { bridgePayload["id"] = id.rawValue }

        guard let requestData = try? JSONSerialization.data(withJSONObject: bridgePayload) else {
            return MCPProtocol.response(id: id, result: MCPProtocol.toolCallError(message: "Failed to encode request"))
        }

        // Synchronous TCP connection to bridge
        let semaphore = DispatchSemaphore(value: 0)
        let receiveState = BridgeReceiveState()

        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: bridgePort)!,
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                let framedData = requestData + Data("\n".utf8)
                connection.send(content: framedData, completion: .contentProcessed { _ in
                    receiveBridgeResponse(
                        on: connection,
                        state: receiveState,
                        semaphore: semaphore
                    )
                })
            } else if case .failed = state {
                semaphore.signal()
            }
        }

        connection.start(queue: .global())
        _ = semaphore.wait(timeout: .now() + 120) // 2 minute timeout for tool execution
        connection.cancel()

        guard let data = receiveState.responseData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return MCPProtocol.response(
                id: id,
                result: MCPProtocol.toolCallError(message: "Bridge connection failed or timed out")
            )
        }

        return MCPProtocol.response(id: id, result: result)
    }

    private static func receiveBridgeResponse(
        on connection: NWConnection,
        state: BridgeReceiveState,
        semaphore: DispatchSemaphore
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: bridgeReceiveChunkSize
        ) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                state.buffer.append(data)
                if let framedData = extractFirstBridgeMessage(from: state.buffer) {
                    state.responseData = framedData
                    semaphore.signal()
                    return
                }
                if state.buffer.count > bridgeMaximumResponseSize {
                    semaphore.signal()
                    return
                }
            }

            if error != nil {
                semaphore.signal()
                return
            }

            if isComplete {
                state.responseData = state.buffer.isEmpty ? nil : state.buffer
                semaphore.signal()
                return
            }

            receiveBridgeResponse(
                on: connection,
                state: state,
                semaphore: semaphore
            )
        }
    }

    static func extractFirstBridgeMessage(from buffer: Data) -> Data? {
        guard let delimiterRange = buffer.range(of: bridgeMessageDelimiter) else {
            return nil
        }
        return buffer.subdata(in: 0..<delimiterRange.lowerBound)
    }
}
