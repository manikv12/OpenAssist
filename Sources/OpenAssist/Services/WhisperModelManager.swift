import CryptoKit
import Foundation

final class WhisperModelManager: NSObject, ObservableObject {
    static let shared = WhisperModelManager()

    enum InstallState: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case installing
        case installed
        case failed(message: String)
    }

    @Published private(set) var installStateByModelID: [String: InstallState] = [:]

    private enum DownloadAssetKind {
        case ggml
        case coreMLZip
    }

    private struct DownloadTaskInfo {
        let modelID: String
        let kind: DownloadAssetKind
    }

    private struct PendingInstall {
        let model: WhisperModelCatalog.Model
        let includeCoreML: Bool
        var ggmlTempURL: URL?
        var coreMLZipTempURL: URL?
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // Large models can take a while on slower or unstable networks.
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 10 * 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        // Model downloads are write-once artifacts; avoid in-memory response caching.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let maxRetryCount = 3
    private var pendingInstallByModelID: [String: PendingInstall] = [:]
    private var taskInfoByTaskID: [Int: DownloadTaskInfo] = [:]
    private var retryCountByTaskKey: [String: Int] = [:]

    private override init() {
        super.init()
        for model in WhisperModelCatalog.curatedModels {
            installStateByModelID[model.id] = .notInstalled
        }
        refreshInstallStates()
    }

    func refreshInstallStates() {
        for model in WhisperModelCatalog.curatedModels {
            if case .downloading = installStateByModelID[model.id] {
                continue
            }
            if case .installing = installStateByModelID[model.id] {
                continue
            }

            installStateByModelID[model.id] = hasInstalledModel(id: model.id)
                ? .installed
                : .notInstalled
        }
    }

    func hasInstalledModel(id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: modelFileURL(for: id).path)
    }

    func installedModelURL(for id: String) -> URL? {
        guard hasInstalledModel(id: id) else { return nil }
        return modelFileURL(for: id)
    }

    func installedCoreMLDirectoryURL(for id: String) -> URL? {
        let url = coreMLDirectoryURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func hasAnyInstalledModel() -> Bool {
        WhisperModelCatalog.curatedModels.contains(where: { hasInstalledModel(id: $0.id) })
    }

    func installModel(modelID: String, includeCoreML: Bool) {
        guard let model = WhisperModelCatalog.model(withID: modelID) else {
            return
        }

        cancelDownload(modelID: modelID)

        pendingInstallByModelID[modelID] = PendingInstall(
            model: model,
            includeCoreML: includeCoreML,
            ggmlTempURL: nil,
            coreMLZipTempURL: nil
        )
        installStateByModelID[modelID] = .downloading(progress: 0)
        startDownload(for: modelID, kind: .ggml)
    }

    func cancelDownload(modelID: String) {
        let taskIDs = taskInfoByTaskID.compactMap { entry -> Int? in
            entry.value.modelID == modelID ? entry.key : nil
        }
        for taskID in taskIDs {
            taskInfoByTaskID.removeValue(forKey: taskID)
        }

        session.getAllTasks { tasks in
            tasks.filter { taskIDs.contains($0.taskIdentifier) }.forEach { $0.cancel() }
        }

        pendingInstallByModelID.removeValue(forKey: modelID)
        retryCountByTaskKey = retryCountByTaskKey.filter { !$0.key.hasPrefix("\(modelID)|") }
        installStateByModelID[modelID] = hasInstalledModel(id: modelID) ? .installed : .notInstalled
    }

    func deleteModel(modelID: String) {
        cancelDownload(modelID: modelID)
        let fm = FileManager.default

        let modelURL = modelFileURL(for: modelID)
        if fm.fileExists(atPath: modelURL.path) {
            try? fm.removeItem(at: modelURL)
        }

        let coreMLURL = coreMLDirectoryURL(for: modelID)
        if fm.fileExists(atPath: coreMLURL.path) {
            try? fm.removeItem(at: coreMLURL)
        }

        installStateByModelID[modelID] = .notInstalled
    }

    private func startDownload(for modelID: String, kind: DownloadAssetKind) {
        guard let pending = pendingInstallByModelID[modelID] else { return }

        let sourceURL: URL
        switch kind {
        case .ggml:
            sourceURL = pending.model.ggmlDownloadURL
        case .coreMLZip:
            guard let coreMLURL = pending.model.coreMLDownloadURL else {
                finalizeInstall(for: modelID)
                return
            }
            sourceURL = coreMLURL
        }

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 10 * 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("OpenAssist/1.0", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        taskInfoByTaskID[task.taskIdentifier] = DownloadTaskInfo(modelID: modelID, kind: kind)
        task.resume()
    }

    private func handleDownloadFinished(taskIdentifier: Int, temporaryLocation: URL) {
        guard let taskInfo = taskInfoByTaskID[taskIdentifier],
              var pending = pendingInstallByModelID[taskInfo.modelID] else {
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openassist-whisper-\(UUID().uuidString)")

        do {
            try FileManager.default.moveItem(at: temporaryLocation, to: tempURL)
        } catch {
            installStateByModelID[taskInfo.modelID] = .failed(message: "Failed to stage download: \(error.localizedDescription)")
            pendingInstallByModelID.removeValue(forKey: taskInfo.modelID)
            return
        }

        switch taskInfo.kind {
        case .ggml:
            retryCountByTaskKey[taskKey(modelID: taskInfo.modelID, kind: .ggml)] = 0
            pending.ggmlTempURL = tempURL
            pendingInstallByModelID[taskInfo.modelID] = pending

            if pending.includeCoreML, pending.model.coreMLDownloadURL != nil {
                startDownload(for: taskInfo.modelID, kind: .coreMLZip)
            } else {
                finalizeInstall(for: taskInfo.modelID)
            }

        case .coreMLZip:
            retryCountByTaskKey[taskKey(modelID: taskInfo.modelID, kind: .coreMLZip)] = 0
            pending.coreMLZipTempURL = tempURL
            pendingInstallByModelID[taskInfo.modelID] = pending
            finalizeInstall(for: taskInfo.modelID)
        }
    }

    private func finalizeInstall(for modelID: String) {
        guard let pending = pendingInstallByModelID.removeValue(forKey: modelID) else {
            return
        }

        installStateByModelID[modelID] = .installing

        Task.detached(priority: .userInitiated) { [pending] in
            do {
                try Self.performInstall(pending: pending)
                await MainActor.run {
                    WhisperModelManager.shared.installStateByModelID[modelID] = .installed
                    WhisperModelManager.shared.refreshInstallStates()
                }
            } catch {
                await MainActor.run {
                    WhisperModelManager.shared.installStateByModelID[modelID] = .failed(message: error.localizedDescription)
                    WhisperModelManager.shared.refreshInstallStates()
                }
            }
        }
    }

    private static func performInstall(pending: PendingInstall) throws {
        let fm = FileManager.default
        let modelsDir = try modelsDirectoryURL()

        guard let ggmlTempURL = pending.ggmlTempURL else {
            throw NSError(domain: "WhisperModelManager", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Model file was not downloaded"])
        }

        if let expectedSHA1 = pending.model.ggmlSHA1, !expectedSHA1.isEmpty {
            let sha = try sha1Hex(of: ggmlTempURL)
            guard sha.caseInsensitiveCompare(expectedSHA1) == .orderedSame else {
                try? fm.removeItem(at: ggmlTempURL)
                throw NSError(domain: "WhisperModelManager", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(pending.model.displayName)"])
            }
        }

        let finalModelURL = modelsDir.appendingPathComponent(pending.model.ggmlFilename)
        try replaceItem(at: finalModelURL, with: ggmlTempURL)

        if let coreMLZipURL = pending.coreMLZipTempURL {
            let extractionRoot = fm.temporaryDirectory.appendingPathComponent("openassist-whisper-coreml-\(UUID().uuidString)")
            try fm.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(at: extractionRoot)
                try? fm.removeItem(at: coreMLZipURL)
            }

            try unzipArchive(from: coreMLZipURL, to: extractionRoot)

            guard let extractedModelDirectory = findDirectory(
                named: pending.model.coreMLDirectoryName,
                under: extractionRoot
            ) else {
                throw NSError(domain: "WhisperModelManager", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Core ML bundle is missing expected folder"])
            }

            let finalCoreMLURL = modelsDir.appendingPathComponent(pending.model.coreMLDirectoryName, isDirectory: true)
            try replaceItem(at: finalCoreMLURL, with: extractedModelDirectory)
        }
    }

    private static func modelsDirectoryURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let openAssistDirectory = appSupport
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        try FileManager.default.createDirectory(at: openAssistDirectory, withIntermediateDirectories: true)
        return openAssistDirectory
    }

    private func modelFileURL(for modelID: String) -> URL {
        let base = (try? Self.modelsDirectoryURL()) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenAssist/Models", isDirectory: true)
        return base.appendingPathComponent("ggml-\(modelID).bin")
    }

    private func coreMLDirectoryURL(for modelID: String) -> URL {
        let base = (try? Self.modelsDirectoryURL()) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenAssist/Models", isDirectory: true)
        return base.appendingPathComponent("ggml-\(modelID)-encoder.mlmodelc", isDirectory: true)
    }

    private func taskKey(modelID: String, kind: DownloadAssetKind) -> String {
        let kindLabel: String
        switch kind {
        case .ggml:
            kindLabel = "ggml"
        case .coreMLZip:
            kindLabel = "coreml"
        }
        return "\(modelID)|\(kindLabel)"
    }

    private func isRetryableNetworkError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorDataNotAllowed,
            NSURLErrorCallIsActive
        ].contains(error.code)
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } else {
            try fm.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func sha1Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func unzipArchive(from archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", archiveURL.path, "-d", destinationURL.path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "WhisperModelManager",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Failed to unzip Core ML bundle: \(stderrText)"]
            )
        }
    }

    private static func findDirectory(named targetName: String, under rootURL: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let next = enumerator?.nextObject() as? URL {
            guard next.lastPathComponent == targetName else { continue }
            if (try? next.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return next
            }
        }

        return nil
    }
}

extension WhisperModelManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard let taskInfo = self.taskInfoByTaskID[downloadTask.taskIdentifier],
                  let pending = self.pendingInstallByModelID[taskInfo.modelID],
                  totalBytesExpectedToWrite > 0
            else {
                return
            }

            let assetProgress = max(0, min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            let overallProgress: Double

            switch taskInfo.kind {
            case .ggml:
                if pending.includeCoreML, pending.model.coreMLDownloadURL != nil {
                    overallProgress = assetProgress * 0.7
                } else {
                    overallProgress = assetProgress
                }

            case .coreMLZip:
                overallProgress = 0.7 + (assetProgress * 0.3)
            }

            self.installStateByModelID[taskInfo.modelID] = .downloading(progress: max(0, min(1, overallProgress)))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if Thread.isMainThread {
            self.handleDownloadFinished(taskIdentifier: downloadTask.taskIdentifier, temporaryLocation: location)
        } else {
            // Move/capture the temporary file before this delegate callback returns,
            // otherwise the system may remove it and staging fails.
            DispatchQueue.main.sync {
                self.handleDownloadFinished(taskIdentifier: downloadTask.taskIdentifier, temporaryLocation: location)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            guard let taskInfo = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) else {
                return
            }

            guard let error else {
                return
            }

            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                self.pendingInstallByModelID.removeValue(forKey: taskInfo.modelID)
                self.installStateByModelID[taskInfo.modelID] = self.hasInstalledModel(id: taskInfo.modelID)
                    ? .installed
                    : .notInstalled
                return
            }

            let retryKey = self.taskKey(modelID: taskInfo.modelID, kind: taskInfo.kind)
            let currentRetryCount = self.retryCountByTaskKey[retryKey, default: 0]
            let hasBaseModelStaged = self.pendingInstallByModelID[taskInfo.modelID]?.ggmlTempURL != nil

            if self.pendingInstallByModelID[taskInfo.modelID] != nil,
               self.isRetryableNetworkError(nsError),
               currentRetryCount < self.maxRetryCount {
                self.retryCountByTaskKey[retryKey] = currentRetryCount + 1
                self.installStateByModelID[taskInfo.modelID] = .downloading(progress: 0)
                self.startDownload(for: taskInfo.modelID, kind: taskInfo.kind)
                return
            }

            // Core ML is optional: if the base ggml model is already staged, finish install without Core ML.
            if taskInfo.kind == .coreMLZip, hasBaseModelStaged {
                self.finalizeInstall(for: taskInfo.modelID)
                return
            }

            self.pendingInstallByModelID.removeValue(forKey: taskInfo.modelID)

            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                self.installStateByModelID[taskInfo.modelID] = .failed(message: "Download timed out. Check network and retry.")
            } else {
                self.installStateByModelID[taskInfo.modelID] = .failed(message: error.localizedDescription)
            }
        }
    }
}
