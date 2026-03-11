import Foundation
import Network

struct AutomationAPIHTTPRequest {
    let method: String
    let target: String
    let path: String
    let headers: [String: String]
    let body: Data

    func headerValue(for name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct AutomationAPIHTTPResponse {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data

    static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> AutomationAPIHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return AutomationAPIHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase(for: statusCode),
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store"
            ],
            body: data
        )
    }

    static func error(_ message: String, statusCode: Int) -> AutomationAPIHTTPResponse {
        json(AutomationAPIErrorResponse(error: message), statusCode: statusCode)
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    func encoded() -> Data {
        var response = Data()
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"

        response.append(Data("HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n".utf8))
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            response.append(Data("\(name): \(value)\r\n".utf8))
        }
        response.append(Data("\r\n".utf8))
        response.append(body)
        return response
    }
}

enum AutomationAPIHTTPParseResult {
    case incomplete
    case complete(AutomationAPIHTTPRequest)
}

enum AutomationAPIHTTPParseError: LocalizedError, Equatable {
    case invalidRequestLine
    case invalidHeaderEncoding
    case invalidContentLength
    case unsupportedTransferEncoding
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidRequestLine:
            return "Invalid HTTP request line."
        case .invalidHeaderEncoding:
            return "Invalid HTTP headers."
        case .invalidContentLength:
            return "Invalid Content-Length header."
        case .unsupportedTransferEncoding:
            return "Chunked transfer encoding is not supported."
        case .payloadTooLarge:
            return "HTTP request payload is too large."
        }
    }
}

final class LocalAutomationServer {
    typealias RequestHandler = @Sendable (AutomationAPIHTTPRequest) async -> AutomationAPIHTTPResponse
    typealias StateHandler = @Sendable (_ isRunning: Bool, _ message: String?) -> Void

    private final class ConnectionContext {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "OpenAssist.AutomationAPI.Server")
    private let maximumPayloadSize = 512 * 1024
    private let stateHandler: StateHandler
    private var listener: NWListener?
    private var requestHandler: RequestHandler?
    private var currentPort: UInt16?

    init(stateHandler: @escaping StateHandler) {
        self.stateHandler = stateHandler
    }

    func start(port: UInt16, requestHandler: @escaping RequestHandler) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            stateHandler(false, "Invalid automation API port.")
            return
        }

        stop(notify: false)
        self.requestHandler = requestHandler

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: endpointPort
            )
            let listener = try NWListener(using: parameters)
            listener.service = nil
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.currentPort = port
                    self.stateHandler(true, nil)
                case .failed(let error):
                    self.listener = nil
                    self.currentPort = nil
                    self.stateHandler(false, error.localizedDescription)
                case .cancelled:
                    self.listener = nil
                    self.currentPort = nil
                    self.stateHandler(false, nil)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard Self.isLoopbackEndpoint(connection.endpoint) else {
                    connection.cancel()
                    return
                }
                self?.handle(connection: connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            self.listener = nil
            self.currentPort = nil
            stateHandler(false, error.localizedDescription)
        }
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        listener?.cancel()
        listener = nil
        requestHandler = nil
        currentPort = nil
        if notify {
            stateHandler(false, nil)
        }
    }

    private func handle(connection: NWConnection) {
        let context = ConnectionContext(connection: connection)
        connection.start(queue: queue)
        receiveNextChunk(for: context)
    }

    private func receiveNextChunk(for context: ConnectionContext) {
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.send(
                    AutomationAPIHTTPResponse.error(error.localizedDescription, statusCode: 500),
                    on: context.connection
                )
                return
            }

            if let data, !data.isEmpty {
                context.buffer.append(data)
            }

            if context.buffer.count > self.maximumPayloadSize {
                self.send(
                    AutomationAPIHTTPResponse.error("HTTP request payload is too large.", statusCode: 413),
                    on: context.connection
                )
                return
            }

            do {
                switch try Self.parseRequest(from: context.buffer, maximumPayloadSize: self.maximumPayloadSize) {
                case .incomplete:
                    if isComplete {
                        self.send(
                            AutomationAPIHTTPResponse.error("Incomplete HTTP request.", statusCode: 400),
                            on: context.connection
                        )
                    } else {
                        self.receiveNextChunk(for: context)
                    }
                case .complete(let request):
                    guard let requestHandler = self.requestHandler else {
                        self.send(
                            AutomationAPIHTTPResponse.error("Automation API is unavailable.", statusCode: 503),
                            on: context.connection
                        )
                        return
                    }
                    Task {
                        let response = await requestHandler(request)
                        self.send(response, on: context.connection)
                    }
                }
            } catch let parseError as AutomationAPIHTTPParseError {
                let statusCode = parseError == .payloadTooLarge ? 413 : 400
                self.send(
                    AutomationAPIHTTPResponse.error(parseError.localizedDescription, statusCode: statusCode),
                    on: context.connection
                )
            } catch {
                self.send(
                    AutomationAPIHTTPResponse.error("Failed to parse HTTP request.", statusCode: 400),
                    on: context.connection
                )
            }
        }
    }

    private func send(_ response: AutomationAPIHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.encoded(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func parseRequest(
        from buffer: Data,
        maximumPayloadSize: Int
    ) throws -> AutomationAPIHTTPParseResult {
        guard let headerBoundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }

        let headerData = buffer.subdata(in: 0..<headerBoundary.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw AutomationAPIHTTPParseError.invalidHeaderEncoding
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            throw AutomationAPIHTTPParseError.invalidRequestLine
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            throw AutomationAPIHTTPParseError.invalidRequestLine
        }

        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            throw AutomationAPIHTTPParseError.unsupportedTransferEncoding
        }

        let contentLengthHeader = headers["content-length"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentLength: Int
        if let contentLengthHeader, !contentLengthHeader.isEmpty {
            guard let parsed = Int(contentLengthHeader), parsed >= 0 else {
                throw AutomationAPIHTTPParseError.invalidContentLength
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        if contentLength > maximumPayloadSize {
            throw AutomationAPIHTTPParseError.payloadTooLarge
        }

        let bodyStart = headerBoundary.upperBound
        let expectedCount = bodyStart + contentLength
        guard buffer.count >= expectedCount else {
            return .incomplete
        }

        let body = contentLength == 0
            ? Data()
            : buffer.subdata(in: bodyStart..<expectedCount)

        return .complete(
            AutomationAPIHTTPRequest(
                method: method,
                target: target,
                path: path,
                headers: headers,
                body: body
            )
        )
    }

    private static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            let value = host.debugDescription.lowercased()
            return value == "127.0.0.1" || value == "::1" || value == "localhost"
        default:
            return false
        }
    }
}
