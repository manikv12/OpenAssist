import Foundation
import Darwin

struct LocalAIRuntimeDetection: Equatable {
    let installed: Bool
    let isManagedInstallation: Bool
    let isHealthy: Bool
    let appURL: URL?
    let executableURL: URL?
    let version: String?

    static let unavailable = LocalAIRuntimeDetection(
        installed: false,
        isManagedInstallation: false,
        isHealthy: false,
        appURL: nil,
        executableURL: nil,
        version: nil
    )
}

enum LocalAIRuntimeError: LocalizedError {
    case runtimeNotInstalled
    case installFailed(reason: String)
    case runtimeStartFailed(reason: String)
    case modelPullFailed(reason: String)
    case modelDeleteFailed(reason: String)
    case canceled

    var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            return "Local AI runtime is not installed yet."
        case .installFailed(let reason):
            return reason
        case .runtimeStartFailed(let reason):
            return reason
        case .modelPullFailed(let reason):
            return reason
        case .modelDeleteFailed(let reason):
            return reason
        case .canceled:
            return "Setup was canceled."
        }
    }
}

protocol LocalAIRuntimeManaging: Sendable {
    func detect() async -> LocalAIRuntimeDetection
    func installManagedRuntime() async throws -> LocalAIRuntimeDetection
    func start() async throws -> LocalAIRuntimeDetection
    func healthCheck() async -> Bool
    func stop() async
    func pullModel(
        id: String,
        onProgress: (@Sendable (Double, String) -> Void)?
    ) async throws
    func deleteModel(id: String) async throws
    func isModelInstalled(_ modelID: String) async -> Bool
    func installedModels() async -> [String]
}

actor LocalAIRuntimeManager: LocalAIRuntimeManaging {
    static let shared = LocalAIRuntimeManager()

    private static let runtimeArchiveURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    private static let runtimeHealthURL = URL(string: "http://127.0.0.1:11434/api/tags")!
    private static let runtimePullURL = URL(string: "http://127.0.0.1:11434/api/pull")!
    private static let runtimeDeleteURL = URL(string: "http://127.0.0.1:11434/api/delete")!

    private let session: URLSession
    private var runtimeProcess: Process?
    private var runtimeExecutablePath: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func detect() async -> LocalAIRuntimeDetection {
        guard let appURL = findRuntimeAppURL(),
              let executableURL = executableURL(for: appURL) else {
            return .unavailable
        }

        let version = runVersion(executableURL: executableURL)
        let healthy = await healthCheck()

        return LocalAIRuntimeDetection(
            installed: true,
            isManagedInstallation: appURL == Self.managedRuntimeAppURL,
            isHealthy: healthy,
            appURL: appURL,
            executableURL: executableURL,
            version: version
        )
    }

    func installManagedRuntime() async throws -> LocalAIRuntimeDetection {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: Self.localRuntimeRootURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw LocalAIRuntimeError.installFailed(reason: "Could not prepare local AI folder: \(error.localizedDescription)")
        }

        let tempZipURL = fileManager.temporaryDirectory.appendingPathComponent("openassist-local-ai-\(UUID().uuidString).zip")
        let extractionRoot = fileManager.temporaryDirectory.appendingPathComponent("openassist-local-ai-runtime-\(UUID().uuidString)")

        do {
            let (downloadedURL, response) = try await session.download(from: Self.runtimeArchiveURL)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw LocalAIRuntimeError.installFailed(reason: "Runtime download failed with HTTP \(http.statusCode).")
            }
            try fileManager.moveItem(at: downloadedURL, to: tempZipURL)
            try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            try Self.unzipArchive(zipURL: tempZipURL, destinationURL: extractionRoot)

            guard let extractedApp = Self.findApp(named: "Ollama.app", under: extractionRoot) else {
                throw LocalAIRuntimeError.installFailed(reason: "Runtime package did not contain Ollama.app.")
            }

            try Self.replaceItem(at: Self.managedRuntimeAppURL, with: extractedApp)
        } catch let runtimeError as LocalAIRuntimeError {
            throw runtimeError
        } catch is CancellationError {
            throw LocalAIRuntimeError.canceled
        } catch {
            throw LocalAIRuntimeError.installFailed(reason: "Could not install local runtime: \(error.localizedDescription)")
        }

        try? fileManager.removeItem(at: tempZipURL)
        try? fileManager.removeItem(at: extractionRoot)

        let detection = await detect()
        guard detection.installed else {
            throw LocalAIRuntimeError.installFailed(reason: "Local runtime install finished, but the runtime was not detected.")
        }
        return detection
    }

    func start() async throws -> LocalAIRuntimeDetection {
        let detection = await detect()
        if detection.isHealthy {
            return detection
        }

        guard let executableURL = detection.executableURL else {
            throw LocalAIRuntimeError.runtimeNotInstalled
        }

        if let runtimeProcess, runtimeProcess.isRunning {
            runtimeProcess.terminate()
            self.runtimeProcess = nil
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["serve"]

        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11434"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw LocalAIRuntimeError.runtimeStartFailed(reason: "Could not start local runtime: \(error.localizedDescription)")
        }

        self.runtimeProcess = process
        self.runtimeExecutablePath = executableURL.path

        let becameHealthy = await waitForHealth(timeoutSeconds: 25)
        guard becameHealthy else {
            process.terminate()
            self.runtimeProcess = nil
            throw LocalAIRuntimeError.runtimeStartFailed(
                reason: "Local runtime started but did not become healthy. Try Repair Local AI in AI Studio."
            )
        }

        return await detect()
    }

    func healthCheck() async -> Bool {
        var request = URLRequest(url: Self.runtimeHealthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    func stop() async {
        // Fast path: if we never started a runtime process, skip expensive process-table scans
        guard runtimeProcess != nil || runtimeExecutablePath != nil else {
            return
        }

        if runtimeExecutablePath == nil,
           let appURL = findRuntimeAppURL(),
           let executableURL = executableURL(for: appURL) {
            runtimeExecutablePath = executableURL.path
        }

        let ownedRuntimePID = runtimeProcess.map { Int32($0.processIdentifier) }
        let processTable = Self.captureProcessTable()
        let ownedChildPIDs = ownedRuntimePID.map { Self.descendantPIDs(of: $0, from: processTable) } ?? []

        if let runtimeProcess, runtimeProcess.isRunning {
            runtimeProcess.terminate()
        }

        if !ownedChildPIDs.isEmpty {
            Self.sendSignal(SIGTERM, to: ownedChildPIDs)
        }

        var ownedPIDsToVerify = ownedChildPIDs
        if let ownedRuntimePID {
            ownedPIDsToVerify.append(ownedRuntimePID)
        }

        if !ownedPIDsToVerify.isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let stillRunningOwned = ownedPIDsToVerify.filter(Self.isProcessRunning)
            if !stillRunningOwned.isEmpty {
                Self.sendSignal(SIGKILL, to: stillRunningOwned)
            }
        }

        if let runtimeExecutablePath {
            let orphanedRunners = Self.orphanedRunnerPIDs(
                executablePath: runtimeExecutablePath,
                from: Self.captureProcessTable()
            )
            if !orphanedRunners.isEmpty {
                Self.sendSignal(SIGTERM, to: orphanedRunners)
                try? await Task.sleep(nanoseconds: 200_000_000)
                let stillRunningOrphans = orphanedRunners.filter(Self.isProcessRunning)
                if !stillRunningOrphans.isEmpty {
                    Self.sendSignal(SIGKILL, to: stillRunningOrphans)
                }
            }
        }

        runtimeProcess = nil
    }

    func pullModel(
        id modelID: String,
        onProgress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        if Task.isCancelled {
            throw LocalAIRuntimeError.canceled
        }

        _ = try await start()

        var request = URLRequest(url: Self.runtimePullURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "name": modelID,
            "stream": true
        ]

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw LocalAIRuntimeError.modelPullFailed(reason: "Could not encode model download request.")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LocalAIRuntimeError.modelPullFailed(reason: "Model download returned an invalid response.")
            }
            guard (200...299).contains(http.statusCode) else {
                throw LocalAIRuntimeError.modelPullFailed(reason: "Model download failed with HTTP \(http.statusCode).")
            }

            var latestStatus = "Preparing model download..."
            onProgress?(0, latestStatus)

            for try await line in bytes.lines {
                if Task.isCancelled {
                    throw LocalAIRuntimeError.canceled
                }

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data, options: []),
                      let dictionary = object as? [String: Any] else {
                    continue
                }

                if let errorMessage = dictionary["error"] as? String,
                   !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LocalAIRuntimeError.modelPullFailed(reason: errorMessage)
                }

                if let status = dictionary["status"] as? String,
                   !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latestStatus = status
                }

                let total = Self.doubleValue(dictionary["total"]) ?? 0
                let completed = Self.doubleValue(dictionary["completed"]) ?? 0
                if total > 0 {
                    let progress = max(0, min(1, completed / total))
                    onProgress?(progress, latestStatus)
                }

                if (dictionary["done"] as? Bool) == true || latestStatus.lowercased().contains("success") {
                    onProgress?(1, "Model download finished.")
                }
            }
        } catch let runtimeError as LocalAIRuntimeError {
            throw runtimeError
        } catch is CancellationError {
            throw LocalAIRuntimeError.canceled
        } catch {
            throw LocalAIRuntimeError.modelPullFailed(reason: "Model download failed: \(error.localizedDescription)")
        }

        let installed = await isModelInstalled(modelID)
        guard installed else {
            throw LocalAIRuntimeError.modelPullFailed(reason: "Model download completed, but verification failed.")
        }
        onProgress?(1, "Model is ready.")
    }

    func installedModels() async -> [String] {
        var request = URLRequest(url: Self.runtimeHealthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dictionary = object as? [String: Any],
                  let models = dictionary["models"] as? [[String: Any]] else {
                return []
            }

            return models.compactMap { model in
                let name = (model["name"] as? String) ?? (model["model"] as? String)
                return name?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    func isModelInstalled(_ modelID: String) async -> Bool {
        let models = await installedModels()
        return models.contains { Self.modelIDsEquivalent($0, modelID) }
    }

    func deleteModel(id modelID: String) async throws {
        if Task.isCancelled {
            throw LocalAIRuntimeError.canceled
        }

        _ = try await start()

        let payload: [String: Any] = ["name": modelID]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw LocalAIRuntimeError.modelDeleteFailed(reason: "Could not encode model delete request.")
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let deleteResult = try await performDeleteRequest(httpMethod: "DELETE", body: body)
            let (data, response) = deleteResult
            guard let http = response as? HTTPURLResponse else {
                throw LocalAIRuntimeError.modelDeleteFailed(reason: "Model delete returned an invalid response.")
            }
            if !(200...299).contains(http.statusCode) {
                // Some runtimes still expect POST for delete.
                if http.statusCode == 404 || http.statusCode == 405 || http.statusCode == 400 {
                    let postResult = try await performDeleteRequest(httpMethod: "POST", body: body)
                    let (postData, postResponse) = postResult
                    guard let postHTTP = postResponse as? HTTPURLResponse else {
                        throw LocalAIRuntimeError.modelDeleteFailed(reason: "Model delete returned an invalid response.")
                    }
                    guard (200...299).contains(postHTTP.statusCode) else {
                        let detail = Self.errorMessage(from: postData) ?? "HTTP \(postHTTP.statusCode)"
                        throw LocalAIRuntimeError.modelDeleteFailed(
                            reason: "Could not delete model \(modelID): \(detail)"
                        )
                    }
                    return
                }
                let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
                throw LocalAIRuntimeError.modelDeleteFailed(
                    reason: "Could not delete model \(modelID): \(detail)"
                )
            }
        } catch let runtimeError as LocalAIRuntimeError {
            throw runtimeError
        } catch is CancellationError {
            throw LocalAIRuntimeError.canceled
        } catch {
            throw LocalAIRuntimeError.modelDeleteFailed(reason: "Model delete failed: \(error.localizedDescription)")
        }
    }

    private func performDeleteRequest(httpMethod: String, body: Data) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: Self.runtimeDeleteURL)
        request.httpMethod = httpMethod
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return try await session.data(for: request)
    }

    private func waitForHealth(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await healthCheck() {
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    private func findRuntimeAppURL() -> URL? {
        for candidate in Self.runtimeAppCandidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func executableURL(for appURL: URL) -> URL? {
        let primary = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ollama", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: primary.path) {
            return primary
        }

        let fallback = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Ollama", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: fallback.path) {
            return fallback
        }

        return nil
    }

    private func runVersion(executableURL: URL) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { return nil }
            return text
        } catch {
            return nil
        }
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func unzipArchive(zipURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", destinationURL.path]

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown unzip error"
            throw LocalAIRuntimeError.installFailed(reason: "Could not unpack runtime: \(message)")
        }
    }

    private static func findApp(named appName: String, under rootURL: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let next = enumerator?.nextObject() as? URL {
            guard next.lastPathComponent == appName,
                  (try? next.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            return next
        }

        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    private static func modelIDsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if left == right {
            return true
        }

        let leftParts = left.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let rightParts = right.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)

        let leftName = String(leftParts.first ?? "")
        let rightName = String(rightParts.first ?? "")
        let leftTag = leftParts.count > 1 ? String(leftParts[1]) : "latest"
        let rightTag = rightParts.count > 1 ? String(rightParts[1]) : "latest"

        if leftName == rightName && (leftTag == rightTag || leftTag == "latest" || rightTag == "latest") {
            return true
        }

        return false
    }

    private struct ProcessTableEntry {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    private static func captureProcessTable() -> [ProcessTableEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command=", "-ww"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }

            return text
                .split(whereSeparator: \.isNewline)
                .compactMap { line in
                    let parts = line.split(
                        maxSplits: 2,
                        omittingEmptySubsequences: true,
                        whereSeparator: { $0 == " " || $0 == "\t" }
                    )
                    guard parts.count == 3,
                          let pid = Int32(parts[0]),
                          let parentPID = Int32(parts[1]) else {
                        return nil
                    }

                    return ProcessTableEntry(
                        pid: pid,
                        parentPID: parentPID,
                        command: String(parts[2])
                    )
                }
        } catch {
            return []
        }
    }

    private static func descendantPIDs(of rootPID: Int32, from processTable: [ProcessTableEntry]) -> [Int32] {
        var childrenByParent: [Int32: [Int32]] = [:]
        for entry in processTable {
            childrenByParent[entry.parentPID, default: []].append(entry.pid)
        }

        var discovered: [Int32] = []
        var queue: [Int32] = [rootPID]
        var visited: Set<Int32> = [rootPID]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = childrenByParent[current] ?? []
            for child in children where !visited.contains(child) {
                visited.insert(child)
                discovered.append(child)
                queue.append(child)
            }
        }

        return discovered
    }

    private static func sendSignal(_ signal: Int32, to pids: [Int32]) {
        for pid in Set(pids) where pid > 1 {
            _ = Darwin.kill(pid, signal)
        }
    }

    private static func isProcessRunning(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func orphanedRunnerPIDs(
        executablePath: String,
        from processTable: [ProcessTableEntry]
    ) -> [Int32] {
        processTable.compactMap { entry in
            guard entry.parentPID == 1 else { return nil }
            guard entry.command.contains(executablePath) else { return nil }
            guard entry.command.contains(" runner ") || entry.command.hasSuffix(" runner") else { return nil }
            return entry.pid
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let dictionary = object as? [String: Any] {
            if let error = dictionary["error"] as? String,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return error
            }
            if let message = dictionary["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }

    private static var localRuntimeRootURL: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupport
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("LocalAI", isDirectory: true)
    }

    private static var managedRuntimeAppURL: URL {
        localRuntimeRootURL.appendingPathComponent("Ollama.app", isDirectory: true)
    }

    private static var runtimeAppCandidates: [URL] {
        [
            managedRuntimeAppURL,
            URL(fileURLWithPath: "/Applications/Ollama.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("Ollama.app", isDirectory: true)
        ]
    }
}
