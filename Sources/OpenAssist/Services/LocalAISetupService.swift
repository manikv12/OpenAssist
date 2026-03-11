import Foundation

enum LocalAISetupState: Equatable {
    case idle
    case waitingForModelSelection
    case installingRuntime
    case downloadingModel(progress: Double)
    case verifying
    case ready
    case failed(message: String)
}

extension LocalAISetupState {
    var isBusy: Bool {
        switch self {
        case .installingRuntime, .downloadingModel, .verifying:
            return true
        case .idle, .waitingForModelSelection, .ready, .failed:
            return false
        }
    }

    var progressValue: Double? {
        if case .downloadingModel(let progress) = self {
            return progress
        }
        return nil
    }

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .waitingForModelSelection:
            return "Select Model"
        case .installingRuntime:
            return "Installing Runtime"
        case .downloadingModel:
            return "Downloading Model"
        case .verifying:
            return "Verifying"
        case .ready:
            return "Ready"
        case .failed:
            return "Needs Attention"
        }
    }
}

@MainActor
final class LocalAISetupService: ObservableObject {
    static let shared = LocalAISetupService()

    @Published private(set) var setupState: LocalAISetupState
    @Published private(set) var statusMessage: String
    @Published private(set) var runtimeDetection: LocalAIRuntimeDetection
    @Published private(set) var installedModelIDs: [String]
    @Published private(set) var lastFailureMessage: String?
    @Published private(set) var modelOptions: [LocalAIModelOption]
    @Published private(set) var isRefreshingWebsiteCatalog = false
    @Published private(set) var websiteCatalogStatusMessage: String?
    @Published var selectedModelID: String {
        didSet {
            let normalized = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized != oldValue else { return }
            settings.localAISelectedModelID = normalized
        }
    }

    private let runtimeManager: LocalAIRuntimeManaging
    private let websiteCatalog: LocalAIWebsiteModelCatalogFetching
    private let settings: SettingsStore
    private var setupTask: Task<Void, Never>?

    init(
        runtimeManager: LocalAIRuntimeManaging = LocalAIRuntimeManager.shared,
        websiteCatalog: LocalAIWebsiteModelCatalogFetching = LocalAIWebsiteModelCatalogService(),
        settings: SettingsStore? = nil
    ) {
        self.runtimeManager = runtimeManager
        self.websiteCatalog = websiteCatalog
        self.settings = settings ?? SettingsStore.shared

        let storedModel = self.settings.localAISelectedModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialModel = storedModel.isEmpty ? LocalAIModelCatalog.recommendedModel.id : storedModel

        self.modelOptions = LocalAIModelCatalog.curatedModels
        self.selectedModelID = initialModel
        self.runtimeDetection = .unavailable
        self.installedModelIDs = []
        self.lastFailureMessage = nil
        self.websiteCatalogStatusMessage = nil
        if initialModel.isEmpty {
            self.setupState = .waitingForModelSelection
            self.statusMessage = "Select a model to start local AI setup."
        } else {
            self.setupState = .idle
            self.statusMessage = "Choose Install to set up local AI."
        }
        ensureModelOptionExists(initialModel)
    }

    deinit {
        setupTask?.cancel()
    }

    func refreshStatus() {
        guard !setupState.isBusy else { return }

        Task {
            let detection = await runtimeManager.detect()
            let installedModels = await runtimeManager.installedModels()
            await MainActor.run {
                applyStatusSnapshot(
                    detection: detection,
                    installedModels: installedModels,
                    preferReadyState: true
                )
            }
        }
    }

    func refreshModelCatalogFromWebsite() {
        guard !isRefreshingWebsiteCatalog else { return }
        isRefreshingWebsiteCatalog = true
        websiteCatalogStatusMessage = "Fetching latest small models from ollama.com (catalog + family tags)..."

        Task { [weak self] in
            guard let self else { return }
            do {
                let websiteModels = try await websiteCatalog.fetchSmallModelOptions(limit: 12)
                await MainActor.run {
                    self.modelOptions = LocalAIModelCatalog.mergedWithWebsiteModels(websiteModels)
                    self.isRefreshingWebsiteCatalog = false

                    let curatedCount = LocalAIModelCatalog.curatedModels.count
                    let addedCount = max(0, self.modelOptions.count - curatedCount)
                    if websiteModels.isEmpty {
                        self.websiteCatalogStatusMessage = "No small website models matched the filter. Showing curated catalog."
                    } else if addedCount > 0 {
                        self.websiteCatalogStatusMessage = "Fetched latest website catalog. Added \(addedCount) new small-model options."
                    } else {
                        self.websiteCatalogStatusMessage = "Fetched latest website catalog. No additional small models beyond curated options."
                    }
                }
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.isRefreshingWebsiteCatalog = false
                    if detail.isEmpty {
                        self.websiteCatalogStatusMessage = "Could not fetch website catalog. Showing curated catalog."
                    } else {
                        self.websiteCatalogStatusMessage = "Could not fetch website catalog: \(detail)"
                    }
                }
            }
        }
    }

    func modelOption(for modelID: String) -> LocalAIModelOption? {
        LocalAIModelCatalog.model(withID: modelID, in: modelOptions)
    }

    private func ensureModelOptionExists(_ modelID: String) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return }
        guard modelOption(for: normalizedModelID) == nil else { return }

        modelOptions.append(
            LocalAIModelOption(
                id: normalizedModelID,
                displayName: normalizedModelID,
                sizeLabel: "Unknown",
                performanceLabel: "Unknown",
                summary: "Existing model from your local configuration.",
                isRecommended: false
            )
        )
    }

    func ensureRuntimeReadyForCurrentConfiguration() {
        guard !setupState.isBusy else { return }
        guard settings.promptRewriteProviderMode == .ollama else { return }

        let providerModel = settings.promptRewriteOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rememberedModel = settings.localAISelectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = providerModel.isEmpty ? rememberedModel : providerModel
        if !resolvedModel.isEmpty {
            ensureModelOptionExists(resolvedModel)
            selectedModelID = resolvedModel
            settings.localAISelectedModelID = resolvedModel
        }

        Task {
            var detection = await runtimeManager.detect()
            var installedModels = await runtimeManager.installedModels()

            if detection.installed && !detection.isHealthy {
                do {
                    detection = try await runtimeManager.start()
                    installedModels = await runtimeManager.installedModels()
                    CrashReporter.logInfo("Local AI runtime auto-started on app launch.")
                } catch {
                    CrashReporter.logWarning(
                        "Local AI runtime auto-start on launch failed: \(error.localizedDescription)"
                    )
                }
            }

            await MainActor.run {
                applyStatusSnapshot(
                    detection: detection,
                    installedModels: installedModels,
                    preferReadyState: true
                )
            }
        }
    }

    func startSetup(modelID: String) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !setupState.isBusy else { return }

        guard !normalizedModelID.isEmpty else {
            setupState = .waitingForModelSelection
            statusMessage = "Select a model first."
            return
        }

        if modelOption(for: normalizedModelID) == nil {
            setupState = .failed(message: "Selected model is not available in the local AI catalog.")
            statusMessage = "Choose one of the listed beginner-friendly models."
            return
        }

        selectedModelID = normalizedModelID
        settings.localAISelectedModelID = normalizedModelID

        if runtimeDetection.isHealthy && Self.matchesInstalledModel(
            normalizedModelID,
            in: installedModelIDs
        ) {
            setupState = .ready
            settings.localAISetupCompleted = true
            statusMessage = "Local AI is already ready with model \(normalizedModelID)."
            return
        }

        setupTask?.cancel()
        setupState = .installingRuntime
        statusMessage = "Checking local runtime..."
        lastFailureMessage = nil
        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.runSetup(modelID: normalizedModelID)
        }
    }

    func cancel() {
        setupTask?.cancel()
        setupTask = nil

        setupState = .idle
        statusMessage = "Local AI setup canceled."
    }

    func retry() {
        let modelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            setupState = .waitingForModelSelection
            statusMessage = "Select a model first."
            return
        }
        startSetup(modelID: modelID)
    }

    func repair() {
        let modelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            setupState = .waitingForModelSelection
            statusMessage = "Select a model first."
            return
        }

        statusMessage = "Repairing local AI runtime and model setup..."
        startSetup(modelID: modelID)
    }

    func deleteSelectedModel() {
        guard !setupState.isBusy else { return }

        let modelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            setupState = .waitingForModelSelection
            statusMessage = "Select a model first."
            return
        }

        guard Self.matchesInstalledModel(modelID, in: installedModelIDs) else {
            statusMessage = "Selected model is not currently installed."
            setupState = .idle
            return
        }

        setupTask?.cancel()
        setupState = .verifying
        statusMessage = "Removing model \(modelID)..."
        lastFailureMessage = nil
        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.runDelete(modelID: modelID)
        }
    }

    var isReady: Bool {
        setupState == .ready
    }

    private func runDelete(modelID: String) async {
        do {
            try await runtimeManager.deleteModel(id: modelID)
            let installedModels = await runtimeManager.installedModels()
            let detection = await runtimeManager.detect()

            await MainActor.run {
                runtimeDetection = detection
                self.installedModelIDs = installedModels
                settings.localAILastHealthCheckEpoch = Date().timeIntervalSince1970

                let selectedStillInstalled = Self.matchesInstalledModel(
                    selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines),
                    in: installedModels
                )
                settings.localAISetupCompleted = detection.isHealthy && selectedStillInstalled

                if settings.promptRewriteProviderMode == .ollama,
                   Self.matchesInstalledModel(settings.promptRewriteOpenAIModel, in: [modelID]),
                   let fallbackInstalled = installedModels.first {
                    settings.promptRewriteOpenAIModel = fallbackInstalled
                }

                setupState = .idle
                statusMessage = "Removed model \(modelID). Install a model to re-enable local rewrite."
                setupTask = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                setupState = .idle
                statusMessage = "Model removal canceled."
                setupTask = nil
            }
        } catch let runtimeError as LocalAIRuntimeError {
            let message = runtimeError.localizedDescription
            await MainActor.run {
                setupState = .failed(message: message)
                statusMessage = message
                lastFailureMessage = message
                setupTask = nil
            }
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? "Could not remove local model." : "Could not remove local model: \(detail)"
            await MainActor.run {
                setupState = .failed(message: message)
                statusMessage = message
                lastFailureMessage = message
                setupTask = nil
            }
        }
    }

    private func runSetup(modelID: String) async {
        await MainActor.run {
            setupState = .installingRuntime
            statusMessage = "Checking local runtime..."
            lastFailureMessage = nil
        }

        do {
            var detection = await runtimeManager.detect()

            if !detection.installed {
                await MainActor.run {
                    setupState = .installingRuntime
                    statusMessage = "Installing local AI runtime..."
                }
                detection = try await runtimeManager.installManagedRuntime()
            }

            await MainActor.run {
                setupState = .verifying
                statusMessage = "Starting local AI runtime..."
            }
            detection = try await runtimeManager.start()

            await MainActor.run {
                setupState = .downloadingModel(progress: 0)
                statusMessage = "Downloading model \(modelID)..."
            }

            try await runtimeManager.pullModel(id: modelID) { [weak self] progress, message in
                Task { @MainActor in
                    guard let self else { return }
                    self.setupState = .downloadingModel(progress: progress)
                    self.statusMessage = message
                }
            }

            await MainActor.run {
                setupState = .verifying
                statusMessage = "Verifying local AI setup..."
            }

            let installed = await runtimeManager.isModelInstalled(modelID)
            guard installed else {
                throw LocalAIRuntimeError.modelPullFailed(reason: "Model verification failed after download.")
            }

            let installedModels = await runtimeManager.installedModels()
            detection = await runtimeManager.detect()

            await MainActor.run {
                installedModelIDs = installedModels
                runtimeDetection = detection
                settings.localAISetupCompleted = true
                settings.localAIManagedRuntimeEnabled = true
                settings.localAISelectedModelID = modelID
                settings.localAIRuntimeVersion = detection.version ?? ""
                settings.localAILastHealthCheckEpoch = Date().timeIntervalSince1970
                settings.applyLocalAIDefaults(selectedModelID: modelID)

                setupState = .ready
                statusMessage = "Local AI is ready. Prompt correction and memory assistant are now configured for local use."
                lastFailureMessage = nil
                setupTask = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                setupState = .idle
                statusMessage = "Local AI setup canceled."
                setupTask = nil
            }
        } catch let runtimeError as LocalAIRuntimeError {
            let message = runtimeError.localizedDescription
            await MainActor.run {
                settings.localAISetupCompleted = false
                setupState = .failed(message: message)
                statusMessage = message
                lastFailureMessage = message
                setupTask = nil
            }
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = message.isEmpty
                ? "Local AI setup failed unexpectedly. Try Repair Local AI."
                : "Local AI setup failed: \(message)"

            await MainActor.run {
                settings.localAISetupCompleted = false
                setupState = .failed(message: fallback)
                statusMessage = fallback
                lastFailureMessage = fallback
                setupTask = nil
            }
        }
    }

    private func applyStatusSnapshot(
        detection: LocalAIRuntimeDetection,
        installedModels: [String],
        preferReadyState: Bool
    ) {
        runtimeDetection = detection
        installedModelIDs = installedModels

        if detection.installed {
            settings.localAIRuntimeVersion = detection.version ?? ""
        }
        settings.localAILastHealthCheckEpoch = Date().timeIntervalSince1970

        let normalizedModelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelectedModel = !normalizedModelID.isEmpty
        let hasInstalledSelectedModel = hasSelectedModel && Self.matchesInstalledModel(
            normalizedModelID,
            in: installedModels
        )

        if !hasSelectedModel {
            setupState = .waitingForModelSelection
            statusMessage = detection.installed
                ? "Runtime is available. Select a model to continue."
                : "Select a model to start setup."
            return
        }

        if preferReadyState && detection.installed && detection.isHealthy && hasInstalledSelectedModel {
            setupState = .ready
            settings.localAISetupCompleted = true
            statusMessage = "Local AI is ready with model \(normalizedModelID)."
            return
        }

        settings.localAISetupCompleted = false
        setupState = .idle

        if !detection.installed {
            statusMessage = "Local runtime is not installed yet."
        } else if !detection.isHealthy {
            statusMessage = "Runtime is installed but not healthy. Run Repair Local AI."
        } else if !hasInstalledSelectedModel {
            statusMessage = "Selected model is not installed yet."
        } else {
            statusMessage = "Local AI is installed."
        }
    }

    private static func matchesInstalledModel(_ selectedModelID: String, in installedModels: [String]) -> Bool {
        installedModels.contains { installed in
            installed.caseInsensitiveCompare(selectedModelID) == .orderedSame
                || installed.lowercased().hasPrefix(selectedModelID.lowercased() + ":")
                || selectedModelID.lowercased().hasPrefix(installed.lowercased() + ":")
        }
    }
}
