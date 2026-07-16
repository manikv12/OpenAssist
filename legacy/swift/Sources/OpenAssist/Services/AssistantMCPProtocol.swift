import Foundation

// MARK: - MCP JSON-RPC Types

enum MCPProtocol {
    static let protocolVersion = "2024-11-05"
    static let serverName = "openassist-tools"
    static let serverVersion = "1.0.0"

    // MARK: - Exposed Tool Names
    //
    // All registered tools are now exposed dynamically via AssistantToolCatalog.
    // The legacy hard-coded set below is kept only as the minimum guarantee when
    // the full catalog is unavailable.

    static let exposedToolNames: Set<String> = [
        "computer_use",
        "computer_batch",
        "spawn_session",
        "screen_capture",
        "window_list",
        "window_capture",
        "list_displays",
        "list_activities",
        "ui_inspect",
        "ui_click",
        "ui_type",
        "ui_press_key",
        "view_image",
        "app_action",
        "browser_use",
        "exec_command",
        "write_stdin",
        "read_terminal",
        "image_generation",
        "assistant_notes"
    ]

    // MARK: - Request Parsing

    struct JSONRPCRequest {
        let id: JSONRPCRequestID?
        let method: String
        let params: [String: Any]

        init?(from data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = json["method"] as? String else {
                return nil
            }
            self.method = method
            self.params = json["params"] as? [String: Any] ?? [:]
            if let rawID = json["id"] {
                self.id = JSONRPCRequestID(rawID)
            } else {
                self.id = nil
            }
        }
    }

    enum JSONRPCRequestID: Sendable {
        case int(Int)
        case string(String)

        init?(_ raw: Any) {
            if let i = raw as? Int {
                self = .int(i)
            } else if let s = raw as? String {
                self = .string(s)
            } else {
                return nil
            }
        }

        var rawValue: Any {
            switch self {
            case .int(let i): return i
            case .string(let s): return s
            }
        }
    }

    // MARK: - Response Building

    static func response(id: JSONRPCRequestID?, result: [String: Any]) -> Data {
        var message: [String: Any] = ["jsonrpc": "2.0"]
        if let id { message["id"] = id.rawValue }
        message["result"] = result
        return encode(message)
    }

    static func errorResponse(id: JSONRPCRequestID?, code: Int, message: String) -> Data {
        var resp: [String: Any] = ["jsonrpc": "2.0"]
        if let id { resp["id"] = id.rawValue }
        resp["error"] = ["code": code, "message": message]
        return encode(resp)
    }

    // MARK: - Initialize Response

    static func initializeResult() -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "capabilities": [
                "tools": [String: Any]()
            ],
            "serverInfo": [
                "name": serverName,
                "version": serverVersion
            ]
        ]
    }

    // MARK: - Tools List Response

    static func toolsListResult(descriptors: [AssistantToolDescriptor]) -> [String: Any] {
        let tools = descriptors.map { descriptor -> [String: Any] in
            [
                "name": descriptor.name,
                "description": descriptor.description,
                "inputSchema": descriptor.inputSchema
            ]
        }
        return ["tools": tools]
    }

    // MARK: - Tool Call Result

    static func toolCallResult(from executionResult: AssistantToolExecutionResult) -> [String: Any] {
        let content = executionResult.contentItems.map { item -> [String: Any] in
            contentItemToMCP(item)
        }
        return [
            "content": content,
            "isError": !executionResult.success
        ]
    }

    static func toolCallError(message: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": message]],
            "isError": true
        ]
    }

    // MARK: - Content Conversion

    static func contentItemToMCP(_ item: AssistantToolExecutionResult.ContentItem) -> [String: Any] {
        if item.type == "inputImage" || item.type == "image",
           let dataURL = item.imageURL,
           let (mimeType, base64Data) = parseDataURL(dataURL) {
            return [
                "type": "image",
                "data": base64Data,
                "mimeType": mimeType
            ]
        }
        return [
            "type": "text",
            "text": item.text ?? item.imageURL ?? ""
        ]
    }

    // MARK: - Bridge Request/Response (TCP)

    struct BridgeRequest: Codable {
        let toolName: String
        let arguments: String // JSON-encoded arguments
        let sessionID: String?
    }

    struct BridgeResponse: Codable {
        let content: [[String: String]]
        let isError: Bool
    }

    // MARK: - Helpers

    private static func parseDataURL(_ dataURL: String) -> (mimeType: String, base64Data: String)? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }
        let metadata = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<commaIndex])
        let base64Data = String(dataURL[dataURL.index(after: commaIndex)...])
        let mimeType = metadata.replacingOccurrences(of: ";base64", with: "")
        return (mimeType, base64Data)
    }

    private static func encode(_ dictionary: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: dictionary, options: [])) ?? Data()
        return data + Data("\n".utf8)
    }
}
