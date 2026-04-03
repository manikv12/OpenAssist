import Foundation

enum GitCheckpointServiceError: LocalizedError {
    case repositoryNotFound(String)
    case gitCommandFailed(String)
    case invalidSnapshotState(String)

    var errorDescription: String? {
        switch self {
        case .repositoryNotFound(let path):
            return "Open Assist could not find a Git repository for \(path)."
        case .gitCommandFailed(let message):
            return message
        case .invalidSnapshotState(let message):
            return message
        }
    }
}

struct GitCheckpointRepositoryContext: Codable, Equatable, Sendable {
    let rootPath: String
    let label: String
}

struct GitCheckpointIgnoredFingerprint: Codable, Equatable, Sendable {
    let path: String
    let size: UInt64
    let modifiedAt: TimeInterval
    let isDirectory: Bool
}

struct GitCheckpointPathState: Codable, Equatable, Sendable {
    let blobID: String?
    let mode: String?
    let objectType: String?

    var exists: Bool {
        blobID?.isEmpty == false && mode?.isEmpty == false
    }

    static let missing = GitCheckpointPathState(blobID: nil, mode: nil, objectType: nil)
}

struct GitCheckpointSnapshot: Codable, Equatable, Sendable {
    let worktreeRef: String
    let worktreeCommit: String
    let worktreeTree: String
    let indexRef: String
    let indexCommit: String
    let indexTree: String
    let ignoredFingerprints: [String: GitCheckpointIgnoredFingerprint]

    init(
        worktreeRef: String,
        worktreeCommit: String,
        worktreeTree: String,
        indexRef: String,
        indexCommit: String,
        indexTree: String,
        ignoredFingerprints: [String: GitCheckpointIgnoredFingerprint]
    ) {
        self.worktreeRef = worktreeRef
        self.worktreeCommit = worktreeCommit
        self.worktreeTree = worktreeTree
        self.indexRef = indexRef
        self.indexCommit = indexCommit
        self.indexTree = indexTree
        self.ignoredFingerprints = ignoredFingerprints
    }

    private enum CodingKeys: String, CodingKey {
        case worktreeRef
        case worktreeCommit
        case worktreeTree
        case indexRef
        case indexCommit
        case indexTree
        case ignoredFingerprints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktreeRef = try container.decode(String.self, forKey: .worktreeRef)
        worktreeCommit = try container.decode(String.self, forKey: .worktreeCommit)
        worktreeTree = try container.decodeIfPresent(String.self, forKey: .worktreeTree)
            ?? worktreeCommit
        indexRef = try container.decode(String.self, forKey: .indexRef)
        indexCommit = try container.decode(String.self, forKey: .indexCommit)
        indexTree = try container.decodeIfPresent(String.self, forKey: .indexTree)
            ?? indexCommit
        ignoredFingerprints = try container.decodeIfPresent(
            [String: GitCheckpointIgnoredFingerprint].self,
            forKey: .ignoredFingerprints
        ) ?? [:]
    }
}

struct GitCheckpointCaptureResult: Equatable, Sendable {
    let patch: String
    let changedFiles: [AssistantCodeCheckpointFile]
    let summary: String
    let ignoredTouchedPaths: [String]
}

struct GitCheckpointCaptureResolution: Equatable, Sendable {
    let capture: GitCheckpointCaptureResult
    let usedUnfilteredFallback: Bool
}

struct GitStoredCheckpointRefState: Equatable, Sendable {
    let checkpointID: String
    let hasBeforeWorktreeRef: Bool
    let hasBeforeIndexRef: Bool
    let hasAfterWorktreeRef: Bool
    let hasAfterIndexRef: Bool

    var hasBeforeSnapshot: Bool {
        hasBeforeWorktreeRef && hasBeforeIndexRef
    }

    var hasAfterSnapshot: Bool {
        hasAfterWorktreeRef && hasAfterIndexRef
    }
}

final class GitCheckpointService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func repositoryContext(for path: String) async throws -> GitCheckpointRepositoryContext? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let result = try await runGit(
            currentDirectoryPath: trimmedPath,
            arguments: ["rev-parse", "--show-toplevel"],
            allowNonZeroExit: true
        )
        guard result.exitCode == 0,
              let rootPath = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty else {
            return nil
        }

        return GitCheckpointRepositoryContext(
            rootPath: rootPath,
            label: URL(fileURLWithPath: rootPath).lastPathComponent
        )
    }

    func captureSnapshot(
        repository: GitCheckpointRepositoryContext,
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) async throws -> GitCheckpointSnapshot {
        let refs = refNames(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: phase
        )

        let worktreeSnapshot = try await captureWorktreeCommit(
            repositoryRootPath: repository.rootPath,
            refName: refs.worktreeRef,
            message: "Open Assist \(phase.rawValue) worktree snapshot"
        )
        let indexSnapshot = try await captureIndexCommit(
            repositoryRootPath: repository.rootPath,
            refName: refs.indexRef,
            message: "Open Assist \(phase.rawValue) index snapshot"
        )

        return GitCheckpointSnapshot(
            worktreeRef: refs.worktreeRef,
            worktreeCommit: worktreeSnapshot.commitID,
            worktreeTree: worktreeSnapshot.treeID,
            indexRef: refs.indexRef,
            indexCommit: indexSnapshot.commitID,
            indexTree: indexSnapshot.treeID,
            // Full ignored-file scans were making checkpoint capture very slow in
            // large repos and could delay live undo/redo availability.
            ignoredFingerprints: [:]
        )
    }

    func captureCurrentState(
        repository: GitCheckpointRepositoryContext
    ) async throws -> (worktreeTree: String, indexTree: String) {
        let checkpointID = "state-\(UUID().uuidString)"
        let refs = refNames(
            sessionID: "transient",
            checkpointID: checkpointID,
            phase: .after
        )

        let worktreeSnapshot = try await captureWorktreeCommit(
            repositoryRootPath: repository.rootPath,
            refName: refs.worktreeRef,
            message: "Open Assist transient worktree state",
            persistRef: false
        )
        let indexSnapshot = try await captureIndexCommit(
            repositoryRootPath: repository.rootPath,
            refName: refs.indexRef,
            message: "Open Assist transient index state",
            persistRef: false
        )
        return (
            worktreeTree: worktreeSnapshot.treeID,
            indexTree: indexSnapshot.treeID
        )
    }

    func storedCheckpointRefs(
        repository: GitCheckpointRepositoryContext,
        sessionID: String
    ) async throws -> [GitStoredCheckpointRefState] {
        let prefix = refPrefix(sessionID: sessionID)
        let result = try await runGit(
            currentDirectoryPath: repository.rootPath,
            arguments: ["for-each-ref", "--format=%(refname)", prefix],
            allowNonZeroExit: true
        )

        guard result.exitCode == 0 else {
            return []
        }

        let rootPrefix = prefix + "/"
        var groupedLeaves: [String: Set<String>] = [:]
        for rawLine in result.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            let refName = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard refName.hasPrefix(rootPrefix) else { continue }

            let remainder = String(refName.dropFirst(rootPrefix.count))
            let components = remainder.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }

            groupedLeaves[components[0], default: []].insert(components[1])
        }

        return groupedLeaves
            .map { checkpointID, leaves in
                GitStoredCheckpointRefState(
                    checkpointID: checkpointID,
                    hasBeforeWorktreeRef: leaves.contains("before-worktree"),
                    hasBeforeIndexRef: leaves.contains("before-index"),
                    hasAfterWorktreeRef: leaves.contains("after-worktree"),
                    hasAfterIndexRef: leaves.contains("after-index")
                )
            }
            .sorted { $0.checkpointID < $1.checkpointID }
    }

    func loadSnapshot(
        repository: GitCheckpointRepositoryContext,
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) async throws -> GitCheckpointSnapshot? {
        let refs = refNames(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: phase
        )

        guard let worktree = try await resolveSnapshotRef(
            repositoryRootPath: repository.rootPath,
            refName: refs.worktreeRef
        ),
        let index = try await resolveSnapshotRef(
            repositoryRootPath: repository.rootPath,
            refName: refs.indexRef
        ) else {
            return nil
        }

        return GitCheckpointSnapshot(
            worktreeRef: refs.worktreeRef,
            worktreeCommit: worktree.commitID,
            worktreeTree: worktree.treeID,
            indexRef: refs.indexRef,
            indexCommit: index.commitID,
            indexTree: index.treeID,
            ignoredFingerprints: [:]
        )
    }

    func buildCaptureResult(
        repository: GitCheckpointRepositoryContext,
        before: GitCheckpointSnapshot,
        after: GitCheckpointSnapshot,
        includedPaths: Set<String>? = nil
    ) async throws -> GitCheckpointCaptureResult {
        let pathFilter = includedPaths?.sorted()
        if let pathFilter, pathFilter.isEmpty {
            return GitCheckpointCaptureResult(
                patch: "",
                changedFiles: [],
                summary: "No Git-tracked code changes were saved in this turn.",
                ignoredTouchedPaths: diffIgnoredPaths(
                    before: before.ignoredFingerprints,
                    after: after.ignoredFingerprints
                )
            )
        }

        let changedStatuses = try await changedPathStatuses(
            repositoryRootPath: repository.rootPath,
            beforeCommit: before.worktreeCommit,
            afterCommit: after.worktreeCommit,
            paths: pathFilter
        )
        let changedPaths = changedStatuses.map(\.path)
        guard !changedPaths.isEmpty else {
            return GitCheckpointCaptureResult(
                patch: "",
                changedFiles: [],
                summary: "No Git-tracked code changes were saved in this turn.",
                ignoredTouchedPaths: diffIgnoredPaths(
                    before: before.ignoredFingerprints,
                    after: after.ignoredFingerprints
                )
            )
        }

        let binaryPaths = try await binaryPathSet(
            repositoryRootPath: repository.rootPath,
            beforeCommit: before.worktreeCommit,
            afterCommit: after.worktreeCommit,
            paths: pathFilter
        )
        let patch = try await diffPatch(
            repositoryRootPath: repository.rootPath,
            beforeCommit: before.worktreeCommit,
            afterCommit: after.worktreeCommit,
            paths: pathFilter
        )

        let files = try await changedStatuses.asyncMap { status in
            AssistantCodeCheckpointFile(
                path: status.path,
                changeKind: status.kind,
                beforeWorktree: try await self.treeEntry(
                    repositoryRootPath: repository.rootPath,
                    commit: before.worktreeCommit,
                    path: status.path
                ),
                afterWorktree: try await self.treeEntry(
                    repositoryRootPath: repository.rootPath,
                    commit: after.worktreeCommit,
                    path: status.path
                ),
                beforeIndex: try await self.treeEntry(
                    repositoryRootPath: repository.rootPath,
                    commit: before.indexCommit,
                    path: status.path
                ),
                afterIndex: try await self.treeEntry(
                    repositoryRootPath: repository.rootPath,
                    commit: after.indexCommit,
                    path: status.path
                ),
                isBinary: binaryPaths.contains(status.path)
            )
        }

        return GitCheckpointCaptureResult(
            patch: patch,
            changedFiles: files,
            summary: plainEnglishSummary(for: files),
            ignoredTouchedPaths: diffIgnoredPaths(
                before: before.ignoredFingerprints,
                after: after.ignoredFingerprints
            )
        )
    }

    func buildCaptureResultWithFullDiffFallback(
        repository: GitCheckpointRepositoryContext,
        before: GitCheckpointSnapshot,
        after: GitCheckpointSnapshot,
        includedPaths: Set<String>?
    ) async throws -> GitCheckpointCaptureResolution {
        let filteredCapture = try await buildCaptureResult(
            repository: repository,
            before: before,
            after: after,
            includedPaths: includedPaths
        )
        guard let includedPaths,
              !includedPaths.isEmpty,
              filteredCapture.changedFiles.isEmpty else {
            return GitCheckpointCaptureResolution(
                capture: filteredCapture,
                usedUnfilteredFallback: false
            )
        }

        let unfilteredCapture = try await buildCaptureResult(
            repository: repository,
            before: before,
            after: after,
            includedPaths: nil
        )
        guard !unfilteredCapture.changedFiles.isEmpty else {
            return GitCheckpointCaptureResolution(
                capture: filteredCapture,
                usedUnfilteredFallback: false
            )
        }

        return GitCheckpointCaptureResolution(
            capture: unfilteredCapture,
            usedUnfilteredFallback: true
        )
    }

    func deleteRefs(for refs: [String], repositoryRootPath: String) async {
        for ref in refs {
            _ = try? await runGit(
                currentDirectoryPath: repositoryRootPath,
                arguments: ["update-ref", "-d", ref],
                allowNonZeroExit: true
            )
        }
    }

    func deleteAllRefs(
        repository: GitCheckpointRepositoryContext,
        sessionID: String
    ) async {
        let prefix = refPrefix(sessionID: sessionID)
        guard let result = try? await runGit(
            currentDirectoryPath: repository.rootPath,
            arguments: ["for-each-ref", "--format=%(refname)", prefix],
            allowNonZeroExit: true
        ), result.exitCode == 0 else {
            return
        }

        let refs = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !refs.isEmpty else { return }
        await deleteRefs(for: refs, repositoryRootPath: repository.rootPath)
    }

    func restore(
        repository: GitCheckpointRepositoryContext,
        files: [AssistantCodeCheckpointFile],
        target: AssistantCodeCheckpointPhase
    ) async throws {
        guard !files.isEmpty else { return }

        let tempIndexURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenAssist-Restore-\(UUID().uuidString).index", isDirectory: false)
        defer {
            try? fileManager.removeItem(at: tempIndexURL)
        }

        try await runGit(
            currentDirectoryPath: repository.rootPath,
            arguments: ["read-tree", "--empty"],
            environment: ["GIT_INDEX_FILE": tempIndexURL.path]
        )

        for file in files {
            let targetIndexState = file.state(for: target, scope: .index)
            try await restoreIndexState(
                repositoryRootPath: repository.rootPath,
                path: file.path,
                state: targetIndexState
            )

            let targetWorktreeState = file.state(for: target, scope: .worktree)
            if targetWorktreeState.exists {
                try await seedTemporaryIndex(
                    repositoryRootPath: repository.rootPath,
                    temporaryIndexPath: tempIndexURL.path,
                    path: file.path,
                    state: targetWorktreeState
                )
                try removeDirectoryIfNeeded(
                    at: URL(fileURLWithPath: repository.rootPath)
                        .appendingPathComponent(file.path, isDirectory: false)
                )
            } else {
                try removeWorktreePath(
                    repositoryRootPath: repository.rootPath,
                    relativePath: file.path
                )
            }
        }

        let checkoutResult = try await runGit(
            currentDirectoryPath: repository.rootPath,
            arguments: ["checkout-index", "--all", "--force"],
            environment: ["GIT_INDEX_FILE": tempIndexURL.path]
        )
        guard checkoutResult.exitCode == 0 else {
            throw GitCheckpointServiceError.gitCommandFailed(
                checkoutResult.stderr.nonEmpty
                    ?? checkoutResult.stdout.nonEmpty
                    ?? "Open Assist could not restore the saved files."
            )
        }
    }

    func restoreGuard(
        repository: GitCheckpointRepositoryContext,
        expectedWorktreeTree: String,
        expectedIndexTree: String
    ) async throws -> AssistantCodeRestoreGuardResult {
        let currentState = try await captureCurrentState(repository: repository)
        guard currentState.worktreeTree == expectedWorktreeTree,
              currentState.indexTree == expectedIndexTree else {
            return AssistantCodeRestoreGuardResult(
                isAllowed: false,
                message: "Open Assist can’t undo right now because the repository changed after the last saved checkpoint."
            )
        }

        return .allowed
    }

    private func captureWorktreeCommit(
        repositoryRootPath: String,
        refName: String,
        message: String,
        persistRef: Bool = true
    ) async throws -> (commitID: String, treeID: String) {
        let tempIndexURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenAssist-Worktree-\(UUID().uuidString).index", isDirectory: false)
        defer {
            try? fileManager.removeItem(at: tempIndexURL)
        }

        let headExists = try await repositoryHasHead(repositoryRootPath: repositoryRootPath)
        if headExists {
            try await runGit(
                currentDirectoryPath: repositoryRootPath,
                arguments: ["read-tree", "HEAD"],
                environment: ["GIT_INDEX_FILE": tempIndexURL.path]
            )
        } else {
            try await runGit(
                currentDirectoryPath: repositoryRootPath,
                arguments: ["read-tree", "--empty"],
                environment: ["GIT_INDEX_FILE": tempIndexURL.path]
            )
        }

        try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["add", "-A", "--", "."],
            environment: ["GIT_INDEX_FILE": tempIndexURL.path]
        )

        let treeWrite = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["write-tree"],
            environment: ["GIT_INDEX_FILE": tempIndexURL.path]
        )
        guard let treeID = treeWrite.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw GitCheckpointServiceError.invalidSnapshotState("Open Assist could not create a saved Git tree for this turn.")
        }

        let commitID = try await createHiddenCommit(
            repositoryRootPath: repositoryRootPath,
            treeID: treeID,
            refName: refName,
            message: message,
            persistRef: persistRef
        )
        return (commitID: commitID, treeID: treeID)
    }

    private func captureIndexCommit(
        repositoryRootPath: String,
        refName: String,
        message: String,
        persistRef: Bool = true
    ) async throws -> (commitID: String, treeID: String) {
        let treeWrite = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["write-tree"]
        )
        guard let treeID = treeWrite.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw GitCheckpointServiceError.invalidSnapshotState("Open Assist could not capture the Git index state for this turn.")
        }

        let commitID = try await createHiddenCommit(
            repositoryRootPath: repositoryRootPath,
            treeID: treeID,
            refName: refName,
            message: message,
            persistRef: persistRef
        )
        return (commitID: commitID, treeID: treeID)
    }

    private func createHiddenCommit(
        repositoryRootPath: String,
        treeID: String,
        refName: String,
        message: String,
        persistRef: Bool
    ) async throws -> String {
        let commitResult = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["commit-tree", treeID, "-m", message],
            environment: [
                "GIT_AUTHOR_NAME": "Open Assist",
                "GIT_AUTHOR_EMAIL": "openassist@local.invalid",
                "GIT_COMMITTER_NAME": "Open Assist",
                "GIT_COMMITTER_EMAIL": "openassist@local.invalid"
            ]
        )
        guard let commitID = commitResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw GitCheckpointServiceError.invalidSnapshotState("Open Assist could not create a hidden Git checkpoint commit.")
        }

        if persistRef {
            _ = try await runGit(
                currentDirectoryPath: repositoryRootPath,
                arguments: ["update-ref", refName, commitID]
            )
        }

        return commitID
    }

    private func repositoryHasHead(repositoryRootPath: String) async throws -> Bool {
        let result = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["rev-parse", "--verify", "HEAD"],
            allowNonZeroExit: true
        )
        return result.exitCode == 0
    }

    private func changedPathStatuses(
        repositoryRootPath: String,
        beforeCommit: String,
        afterCommit: String,
        paths: [String]? = nil
    ) async throws -> [(path: String, kind: AssistantCodeCheckpointChangeKind)] {
        var arguments = ["diff", "--no-renames", "--name-status", "-z", beforeCommit, afterCommit, "--"]
        if let paths {
            arguments.append(contentsOf: paths)
        }
        let result = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: arguments
        )

        let chunks = result.stdout.split(separator: "\0").map(String.init)
        var statuses: [(path: String, kind: AssistantCodeCheckpointChangeKind)] = []
        var index = 0
        while index + 1 < chunks.count {
            let status = chunks[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let path = chunks[index + 1]
            index += 2

            guard let path = path.nonEmpty else { continue }
            statuses.append((path, AssistantCodeCheckpointChangeKind(statusSymbol: status)))
        }
        return statuses
    }

    private func binaryPathSet(
        repositoryRootPath: String,
        beforeCommit: String,
        afterCommit: String,
        paths: [String]? = nil
    ) async throws -> Set<String> {
        var arguments = ["diff", "--no-renames", "--numstat", "-z", beforeCommit, afterCommit, "--"]
        if let paths {
            arguments.append(contentsOf: paths)
        }
        let result = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: arguments
        )

        let rows = result.stdout.split(separator: "\0").map(String.init)
        var paths: Set<String> = []
        for row in rows {
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3 else { continue }
            if columns[0] == "-" || columns[1] == "-" {
                paths.insert(columns[2])
            }
        }
        return paths
    }

    private func diffPatch(
        repositoryRootPath: String,
        beforeCommit: String,
        afterCommit: String,
        paths: [String]? = nil
    ) async throws -> String {
        var arguments = ["diff", "--no-renames", "--binary", beforeCommit, afterCommit, "--"]
        if let paths {
            arguments.append(contentsOf: paths)
        }
        let result = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: arguments
        )
        return result.stdout
    }

    private func treeEntry(
        repositoryRootPath: String,
        commit: String,
        path: String
    ) async throws -> GitCheckpointPathState {
        let result = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["ls-tree", "-z", commit, "--", path],
            allowNonZeroExit: true
        )
        guard result.exitCode == 0 else {
            return .missing
        }

        let trimmed = result.stdout.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard let line = trimmed.nonEmpty,
              let tabIndex = line.firstIndex(of: "\t") else {
            return .missing
        }

        let metadata = line[..<tabIndex]
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard metadata.count >= 3 else {
            return .missing
        }

        return GitCheckpointPathState(
            blobID: metadata[2],
            mode: metadata[0],
            objectType: metadata[1]
        )
    }

    private func ignoredFingerprints(
        in repositoryRootPath: String
    ) -> [String: GitCheckpointIgnoredFingerprint] {
        guard let result = try? runSyncGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["ls-files", "-o", "-i", "--exclude-standard", "-z"]
        ) else {
            return [:]
        }

        let paths = result.stdout.split(separator: "\0").map(String.init)
        var fingerprints: [String: GitCheckpointIgnoredFingerprint] = [:]
        for path in paths {
            let absoluteURL = URL(fileURLWithPath: repositoryRootPath).appendingPathComponent(path, isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: absoluteURL.path) else {
                continue
            }

            let type = attributes[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

            fingerprints[path] = GitCheckpointIgnoredFingerprint(
                path: path,
                size: size,
                modifiedAt: modifiedAt,
                isDirectory: isDirectory
            )
        }
        return fingerprints
    }

    private func diffIgnoredPaths(
        before: [String: GitCheckpointIgnoredFingerprint],
        after: [String: GitCheckpointIgnoredFingerprint]
    ) -> [String] {
        let keys = Set(before.keys).union(after.keys)
        return keys
            .filter { before[$0] != after[$0] }
            .sorted()
    }

    private func plainEnglishSummary(for files: [AssistantCodeCheckpointFile]) -> String {
        let added = files.filter { $0.changeKind == .added }.count
        let deleted = files.filter { $0.changeKind == .deleted }.count
        let modified = files.filter { $0.changeKind == .modified || $0.changeKind == .changed || $0.changeKind == .typeChanged }.count

        var parts: [String] = []
        if added > 0 {
            parts.append("added \(added) file\(added == 1 ? "" : "s")")
        }
        if modified > 0 {
            parts.append("updated \(modified) file\(modified == 1 ? "" : "s")")
        }
        if deleted > 0 {
            parts.append("removed \(deleted) file\(deleted == 1 ? "" : "s")")
        }

        guard !parts.isEmpty else {
            return "Saved a Git-backed code checkpoint."
        }

        let joined: String
        if parts.count == 1 {
            joined = parts[0]
        } else if parts.count == 2 {
            joined = "\(parts[0]) and \(parts[1])"
        } else {
            joined = "\(parts[0]), \(parts[1]), and \(parts[2])"
        }
        return "Saved a checkpoint that \(joined)."
    }

    private func restoreIndexState(
        repositoryRootPath: String,
        path: String,
        state: GitCheckpointPathState
    ) async throws {
        if state.exists,
           let mode = state.mode,
           let blobID = state.blobID {
            _ = try await runGit(
                currentDirectoryPath: repositoryRootPath,
                arguments: ["update-index", "--add", "--cacheinfo", mode, blobID, path]
            )
        } else {
            _ = try await runGit(
                currentDirectoryPath: repositoryRootPath,
                arguments: ["update-index", "--force-remove", "--", path],
                allowNonZeroExit: true
            )
        }
    }

    private func seedTemporaryIndex(
        repositoryRootPath: String,
        temporaryIndexPath: String,
        path: String,
        state: GitCheckpointPathState
    ) async throws {
        guard state.exists,
              let mode = state.mode,
              let blobID = state.blobID else {
            return
        }

        _ = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["update-index", "--add", "--cacheinfo", mode, blobID, path],
            environment: ["GIT_INDEX_FILE": temporaryIndexPath]
        )
    }

    private func removeWorktreePath(
        repositoryRootPath: String,
        relativePath: String
    ) throws {
        let absoluteURL = URL(fileURLWithPath: repositoryRootPath)
            .appendingPathComponent(relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: absoluteURL.path) else { return }
        try fileManager.removeItem(at: absoluteURL)

        var currentDirectory = absoluteURL.deletingLastPathComponent()
        let rootURL = URL(fileURLWithPath: repositoryRootPath)
        while currentDirectory.path.hasPrefix(rootURL.path),
              currentDirectory.path != rootURL.path {
            guard let children = try? fileManager.contentsOfDirectory(atPath: currentDirectory.path),
                  children.isEmpty else {
                break
            }
            try? fileManager.removeItem(at: currentDirectory)
            currentDirectory = currentDirectory.deletingLastPathComponent()
        }
    }

    private func removeDirectoryIfNeeded(at fileURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func refNames(
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) -> (worktreeRef: String, indexRef: String) {
        let safeSessionID = sanitizeRefPathComponent(sessionID)
        let safeCheckpointID = sanitizeRefPathComponent(checkpointID)
        let prefix = "refs/openassist/checkpoints/\(safeSessionID)/\(safeCheckpointID)/\(phase.rawValue)"
        return (
            worktreeRef: "\(prefix)-worktree",
            indexRef: "\(prefix)-index"
        )
    }

    private func refPrefix(sessionID: String) -> String {
        "refs/openassist/checkpoints/\(sanitizeRefPathComponent(sessionID))"
    }

    private func sanitizeRefPathComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
    }

    private func resolveSnapshotRef(
        repositoryRootPath: String,
        refName: String
    ) async throws -> (commitID: String, treeID: String)? {
        let commitResult = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["rev-parse", "--verify", refName],
            allowNonZeroExit: true
        )
        guard commitResult.exitCode == 0,
              let commitID = commitResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let treeResult = try await runGit(
            currentDirectoryPath: repositoryRootPath,
            arguments: ["rev-parse", "--verify", "\(refName)^{tree}"],
            allowNonZeroExit: true
        )
        guard treeResult.exitCode == 0,
              let treeID = treeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        return (commitID: commitID, treeID: treeID)
    }

    @discardableResult
    private func runGit(
        currentDirectoryPath: String,
        arguments: [String],
        environment: [String: String] = [:],
        allowNonZeroExit: Bool = false
    ) async throws -> CommandExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let captures: GitCommandOutputCapture
            do {
                captures = try makeGitCommandOutputCapture()
            } catch {
                continuation.resume(
                    throwing: GitCheckpointServiceError.gitCommandFailed(
                        "Open Assist could not prepare Git output capture: \(error.localizedDescription)"
                    )
                )
                return
            }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)

            var mergedEnvironment = AssistantCommandEnvironment.mergedEnvironment()
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
            process.environment = mergedEnvironment
            process.standardOutput = captures.stdoutHandle
            process.standardError = captures.stderrHandle

            process.terminationHandler = { completed in
                do {
                    try? captures.stdoutHandle.close()
                    try? captures.stderrHandle.close()
                    let result = try self.readGitCommandOutput(
                        captures,
                        exitCode: completed.terminationStatus
                    )
                    self.cleanupGitCommandOutputCapture(captures)

                    if completed.terminationStatus != 0 && !allowNonZeroExit {
                        continuation.resume(
                            throwing: GitCheckpointServiceError.gitCommandFailed(
                                result.stderr
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .nonEmpty
                                    ?? result.stdout
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .nonEmpty
                                    ?? "Git command failed: git \(arguments.joined(separator: " "))"
                            )
                        )
                    } else {
                        continuation.resume(returning: result)
                    }
                } catch {
                    self.cleanupGitCommandOutputCapture(captures)
                    continuation.resume(
                        throwing: GitCheckpointServiceError.gitCommandFailed(
                            "Open Assist could not read Git output: \(error.localizedDescription)"
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                try? captures.stdoutHandle.close()
                try? captures.stderrHandle.close()
                cleanupGitCommandOutputCapture(captures)
                continuation.resume(
                    throwing: GitCheckpointServiceError.gitCommandFailed(
                        "Open Assist could not run Git: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func runSyncGit(
        currentDirectoryPath: String,
        arguments: [String]
    ) throws -> CommandExecutionResult {
        let process = Process()
        let captures = try makeGitCommandOutputCapture()
        defer {
            try? captures.stdoutHandle.close()
            try? captures.stderrHandle.close()
            cleanupGitCommandOutputCapture(captures)
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        process.environment = AssistantCommandEnvironment.mergedEnvironment()
        process.standardOutput = captures.stdoutHandle
        process.standardError = captures.stderrHandle

        do {
            try process.run()
        } catch {
            throw GitCheckpointServiceError.gitCommandFailed(
                "Open Assist could not run Git: \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()
        try? captures.stdoutHandle.close()
        try? captures.stderrHandle.close()
        let result = try readGitCommandOutput(captures, exitCode: process.terminationStatus)
        guard result.exitCode == 0 else {
            throw GitCheckpointServiceError.gitCommandFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "Git command failed: git \(arguments.joined(separator: " "))"
            )
        }
        return result
    }

    private struct GitCommandOutputCapture {
        let stdoutURL: URL
        let stderrURL: URL
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
    }

    private func makeGitCommandOutputCapture() throws -> GitCommandOutputCapture {
        let directory = fileManager.temporaryDirectory
        let stdoutURL = directory.appendingPathComponent(
            "OpenAssist-Git-\(UUID().uuidString).stdout",
            isDirectory: false
        )
        let stderrURL = directory.appendingPathComponent(
            "OpenAssist-Git-\(UUID().uuidString).stderr",
            isDirectory: false
        )

        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
            fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
            throw GitCheckpointServiceError.gitCommandFailed(
                "Open Assist could not create temporary files for Git output."
            )
        }

        return GitCommandOutputCapture(
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            stdoutHandle: try FileHandle(forWritingTo: stdoutURL),
            stderrHandle: try FileHandle(forWritingTo: stderrURL)
        )
    }

    private func readGitCommandOutput(
        _ captures: GitCommandOutputCapture,
        exitCode: Int32
    ) throws -> CommandExecutionResult {
        let stdoutData = try Data(contentsOf: captures.stdoutURL)
        let stderrData = try Data(contentsOf: captures.stderrURL)
        return CommandExecutionResult(
            exitCode: exitCode,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func cleanupGitCommandOutputCapture(_ captures: GitCommandOutputCapture) {
        try? fileManager.removeItem(at: captures.stdoutURL)
        try? fileManager.removeItem(at: captures.stderrURL)
    }
}

private enum GitCheckpointStateScope {
    case worktree
    case index
}

private extension AssistantCodeCheckpointFile {
    func state(
        for phase: AssistantCodeCheckpointPhase,
        scope: GitCheckpointStateScope
    ) -> GitCheckpointPathState {
        switch (phase, scope) {
        case (.before, .worktree):
            return beforeWorktree
        case (.before, .index):
            return beforeIndex
        case (.after, .worktree):
            return afterWorktree
        case (.after, .index):
            return afterIndex
        }
    }
}

private extension AssistantCodeCheckpointChangeKind {
    init(statusSymbol: String) {
        switch statusSymbol.uppercased() {
        case "A":
            self = .added
        case "D":
            self = .deleted
        case "T":
            self = .typeChanged
        case "M":
            self = .modified
        default:
            self = .changed
        }
    }
}

private extension Array {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            let transformed = try await transform(element)
            results.append(transformed)
        }
        return results
    }
}
