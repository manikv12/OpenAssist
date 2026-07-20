import Foundation
import Network

protocol RemoteAccessEventSink: AnyObject {
    var onClose: (() -> Void)? { get set }
    func send(event: RemoteAccessEvent)
    func close()
}

enum RemoteAccessServerResult {
    case response(AutomationAPIHTTPResponse)
    case eventStream((RemoteAccessEventSink) -> Void)
}

final class RemoteAccessHTTPServer {
    typealias RequestHandler = @Sendable (AutomationAPIHTTPRequest) async -> RemoteAccessServerResult
    typealias StateHandler = @Sendable (_ isRunning: Bool, _ message: String?) -> Void

    private final class ConnectionContext {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private final class EventStreamConnection: RemoteAccessEventSink {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let encoder: JSONEncoder
        private var isClosed = false
        private var heartbeatTimer: DispatchSourceTimer?
        var onClose: (() -> Void)?

        init(connection: NWConnection, queue: DispatchQueue) {
            self.connection = connection
            self.queue = queue
            self.encoder = JSONEncoder()
            self.encoder.dateEncodingStrategy = .iso8601
        }

        func start() {
            queue.async {
                guard !self.isClosed else { return }
                let headers = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: text/event-stream; charset=utf-8",
                    "Cache-Control: no-store",
                    "Connection: keep-alive",
                    "X-Accel-Buffering: no",
                    "",
                    ""
                ].joined(separator: "\r\n")
                self.connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.close()
                        return
                    }
                    self?.startHeartbeat()
                    self?.watchForDisconnect()
                })
            }
        }

        func send(event: RemoteAccessEvent) {
            queue.async {
                guard !self.isClosed,
                      let data = try? self.encoder.encode(event),
                      let text = String(data: data, encoding: .utf8) else {
                    return
                }
                let payload = Data("data: \(text)\n\n".utf8)
                self.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.close()
                    }
                })
            }
        }

        func close() {
            queue.async {
                guard !self.isClosed else { return }
                self.isClosed = true
                self.heartbeatTimer?.cancel()
                self.heartbeatTimer = nil
                self.connection.cancel()
                self.onClose?()
            }
        }

        private func startHeartbeat() {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                guard let self, !self.isClosed else { return }
                self.connection.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.close()
                    }
                })
            }
            heartbeatTimer = timer
            timer.resume()
        }

        private func watchForDisconnect() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
                guard let self else { return }
                if isComplete || error != nil {
                    self.close()
                    return
                }
                self.watchForDisconnect()
            }
        }
    }

    private let queue = DispatchQueue(label: "OpenAssist.RemoteAccess.Server")
    private let maximumPayloadSize = 1024 * 1024
    private let stateHandler: StateHandler
    private var listener: NWListener?
    private var requestHandler: RequestHandler?

    init(stateHandler: @escaping StateHandler) {
        self.stateHandler = stateHandler
    }

    func start(port: UInt16, requestHandler: @escaping RequestHandler) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            stateHandler(false, "Invalid remote access port.")
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
                    self.stateHandler(true, nil)
                case .failed(let error):
                    self.listener = nil
                    self.stateHandler(false, error.localizedDescription)
                case .cancelled:
                    self.listener = nil
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
            self.stateHandler(false, error.localizedDescription)
        }
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        listener?.cancel()
        listener = nil
        requestHandler = nil
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
                switch try LocalAutomationServer.parseRequest(
                    from: context.buffer,
                    maximumPayloadSize: self.maximumPayloadSize
                ) {
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
                            AutomationAPIHTTPResponse.error("Remote access helper is unavailable.", statusCode: 503),
                            on: context.connection
                        )
                        return
                    }
                    Task {
                        let result = await requestHandler(request)
                        switch result {
                        case .response(let response):
                            self.send(response, on: context.connection)
                        case .eventStream(let configure):
                            let sink = EventStreamConnection(connection: context.connection, queue: self.queue)
                            sink.start()
                            configure(sink)
                        }
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
