import Foundation
import XCTest
@testable import OpenAssist

final class GitCheckpointServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testRepositoryContextFindsRepoRootFromNestedPath() async throws {
        let repositoryURL = try makeGitRepository()
        let nestedDirectory = repositoryURL
            .appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: nestedDirectory.path)
        let context = try XCTUnwrap(resolvedContext)

        XCTAssertEqual(
            URL(fileURLWithPath: context.rootPath).resolvingSymlinksInPath().path,
            repositoryURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(context.label, repositoryURL.lastPathComponent)
    }

    func testCaptureResultExcludesIgnoredFilesAndIncludesTrackedCreations() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        let checkpointID = UUID().uuidString
        let before = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-capture",
            checkpointID: checkpointID,
            phase: .before
        )

        try write("after\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try write("new file\n", to: repositoryURL.appendingPathComponent("new-file.txt"))
        try write("ignored drift\n", to: repositoryURL.appendingPathComponent("ignored.tmp"))

        let after = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-capture",
            checkpointID: checkpointID,
            phase: .after
        )
        let capture = try await service.buildCaptureResult(
            repository: context,
            before: before,
            after: after
        )

        XCTAssertEqual(
            Set(capture.changedFiles.map(\.path)),
            Set(["tracked.txt", "new-file.txt"])
        )
        XCTAssertTrue(capture.ignoredTouchedPaths.contains("ignored.tmp"))
        XCTAssertFalse(capture.changedFiles.contains(where: { $0.path == "ignored.tmp" }))
        XCTAssertFalse(capture.patch.isEmpty)
    }

    func testRestoreMovesBetweenBeforeAndAfterSnapshots() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        let checkpointID = UUID().uuidString
        let before = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-restore",
            checkpointID: checkpointID,
            phase: .before
        )

        try write("after\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try write("created later\n", to: repositoryURL.appendingPathComponent("new-file.txt"))
        try write("ignored change\n", to: repositoryURL.appendingPathComponent("ignored.tmp"))

        let after = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-restore",
            checkpointID: checkpointID,
            phase: .after
        )
        let capture = try await service.buildCaptureResult(
            repository: context,
            before: before,
            after: after
        )

        let allowRestore = try await service.restoreGuard(
            repository: context,
            expectedWorktreeTree: after.worktreeTree,
            expectedIndexTree: after.indexTree
        )
        XCTAssertTrue(allowRestore.isAllowed)

        try await service.restore(
            repository: context,
            files: capture.changedFiles,
            target: .before
        )

        XCTAssertEqual(
            try String(contentsOf: repositoryURL.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "before\n"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryURL.appendingPathComponent("new-file.txt").path
            )
        )
        XCTAssertEqual(
            try String(contentsOf: repositoryURL.appendingPathComponent("ignored.tmp"), encoding: .utf8),
            "ignored change\n"
        )

        try await service.restore(
            repository: context,
            files: capture.changedFiles,
            target: .after
        )

        XCTAssertEqual(
            try String(contentsOf: repositoryURL.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "after\n"
        )
        XCTAssertEqual(
            try String(contentsOf: repositoryURL.appendingPathComponent("new-file.txt"), encoding: .utf8),
            "created later\n"
        )
    }

    func testCaptureResultCanBeLimitedToTouchedPaths() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        try write("assistant before\n", to: repositoryURL.appendingPathComponent("assistant.txt"))
        try write("external before\n", to: repositoryURL.appendingPathComponent("external.txt"))
        try runGit(["add", "assistant.txt", "external.txt"], in: repositoryURL)
        try runGit(["commit", "-m", "Add tracked fixtures"], in: repositoryURL)

        let checkpointID = UUID().uuidString
        let before = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-filtered-capture",
            checkpointID: checkpointID,
            phase: .before
        )

        try write("assistant after\n", to: repositoryURL.appendingPathComponent("assistant.txt"))
        try write("external after\n", to: repositoryURL.appendingPathComponent("external.txt"))

        let after = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-filtered-capture",
            checkpointID: checkpointID,
            phase: .after
        )
        let capture = try await service.buildCaptureResult(
            repository: context,
            before: before,
            after: after,
            includedPaths: ["assistant.txt"]
        )

        XCTAssertEqual(capture.changedFiles.map(\.path), ["assistant.txt"])
        XCTAssertTrue(capture.patch.contains("assistant.txt"))
        XCTAssertFalse(capture.patch.contains("external.txt"))
    }

    func testFilteredCaptureCanFallBackToFullDiffWhenTouchedPathsMissTrackedChanges() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        try write("real change\n", to: repositoryURL.appendingPathComponent("real-change.txt"))
        try runGit(["add", "real-change.txt"], in: repositoryURL)
        try runGit(["commit", "-m", "Add real change fixture"], in: repositoryURL)

        let checkpointID = UUID().uuidString
        let before = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-filter-fallback",
            checkpointID: checkpointID,
            phase: .before
        )

        try write("updated content\n", to: repositoryURL.appendingPathComponent("real-change.txt"))

        let after = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-filter-fallback",
            checkpointID: checkpointID,
            phase: .after
        )

        let resolvedCapture = try await service.buildCaptureResultWithFullDiffFallback(
            repository: context,
            before: before,
            after: after,
            includedPaths: ["wrong-file.txt"]
        )

        XCTAssertTrue(resolvedCapture.usedUnfilteredFallback)
        XCTAssertEqual(resolvedCapture.capture.changedFiles.map(\.path), ["real-change.txt"])
        XCTAssertTrue(resolvedCapture.capture.patch.contains("real-change.txt"))
    }

    func testStoredCheckpointRefsExposeIncompleteBeforeSnapshot() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        let checkpointID = UUID().uuidString
        let before = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-ref-scan",
            checkpointID: checkpointID,
            phase: .before
        )

        let storedRefs = try await service.storedCheckpointRefs(
            repository: context,
            sessionID: "thread-ref-scan"
        )
        let stored = try XCTUnwrap(storedRefs.first(where: { $0.checkpointID == checkpointID }))
        XCTAssertTrue(stored.hasBeforeSnapshot)
        XCTAssertFalse(stored.hasAfterSnapshot)

        let loadedBefore = try await service.loadSnapshot(
            repository: context,
            sessionID: "thread-ref-scan",
            checkpointID: checkpointID,
            phase: .before
        )
        let loadedAfter = try await service.loadSnapshot(
            repository: context,
            sessionID: "thread-ref-scan",
            checkpointID: checkpointID,
            phase: .after
        )

        XCTAssertEqual(loadedBefore, before)
        XCTAssertNil(loadedAfter)
    }

    func testStoredCheckpointRefsCanReloadCompletedCheckpointSnapshots() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        let checkpointID = UUID().uuidString
        let before = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-complete-ref-scan",
            checkpointID: checkpointID,
            phase: .before
        )

        try FileManager.default.removeItem(at: repositoryURL.appendingPathComponent("tracked.txt"))

        let after = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-complete-ref-scan",
            checkpointID: checkpointID,
            phase: .after
        )

        let storedRefs = try await service.storedCheckpointRefs(
            repository: context,
            sessionID: "thread-complete-ref-scan"
        )
        let stored = try XCTUnwrap(storedRefs.first(where: { $0.checkpointID == checkpointID }))
        XCTAssertTrue(stored.hasBeforeSnapshot)
        XCTAssertTrue(stored.hasAfterSnapshot)

        let loadedBefore = try await service.loadSnapshot(
            repository: context,
            sessionID: "thread-complete-ref-scan",
            checkpointID: checkpointID,
            phase: .before
        )
        let loadedAfter = try await service.loadSnapshot(
            repository: context,
            sessionID: "thread-complete-ref-scan",
            checkpointID: checkpointID,
            phase: .after
        )

        XCTAssertEqual(loadedBefore, before)
        XCTAssertEqual(loadedAfter, after)
    }

    func testDeletionCheckpointCanBeCapturedAndRestored() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        try write("# Claude instructions\n", to: repositoryURL.appendingPathComponent("CLAUDE.md"))
        try runGit(["add", "CLAUDE.md"], in: repositoryURL)
        try runGit(["commit", "-m", "Add CLAUDE"], in: repositoryURL)

        let checkpointID = UUID().uuidString
        let before = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-delete",
            checkpointID: checkpointID,
            phase: .before
        )

        try FileManager.default.removeItem(at: repositoryURL.appendingPathComponent("CLAUDE.md"))

        let after = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-delete",
            checkpointID: checkpointID,
            phase: .after
        )
        let capture = try await service.buildCaptureResult(
            repository: context,
            before: before,
            after: after
        )

        XCTAssertEqual(capture.changedFiles.map(\.path), ["CLAUDE.md"])
        XCTAssertEqual(capture.changedFiles.first?.changeKind, .deleted)

        try await service.restore(
            repository: context,
            files: capture.changedFiles,
            target: .before
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryURL.appendingPathComponent("CLAUDE.md").path
            )
        )
        XCTAssertEqual(
            try String(contentsOf: repositoryURL.appendingPathComponent("CLAUDE.md"), encoding: .utf8),
            "# Claude instructions\n"
        )
    }

    func testRestoreGuardBlocksDriftAfterCheckpoint() async throws {
        let repositoryURL = try makeGitRepository()
        let service = GitCheckpointService()
        let resolvedContext = try await service.repositoryContext(for: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        let checkpointID = UUID().uuidString
        _ = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-drift",
            checkpointID: checkpointID,
            phase: .before
        )

        try write("after\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        let after = try await service.captureSnapshot(
            repository: context,
            sessionID: "thread-drift",
            checkpointID: checkpointID,
            phase: .after
        )

        try write("manual drift\n", to: repositoryURL.appendingPathComponent("tracked.txt"))

        let guardResult = try await service.restoreGuard(
            repository: context,
            expectedWorktreeTree: after.worktreeTree,
            expectedIndexTree: after.indexTree
        )

        XCTAssertFalse(guardResult.isAllowed)
        XCTAssertEqual(
            guardResult.message,
            "Open Assist can’t undo right now because the repository changed after the last saved checkpoint."
        )
    }

    private func makeGitRepository() throws -> URL {
        let repositoryURL = try makeTemporaryDirectory(named: "GitCheckpointServiceTests")
        try runGit(["init", "-b", "main"], in: repositoryURL)
        try write("ignored.tmp\n", to: repositoryURL.appendingPathComponent(".gitignore"))
        try write("before\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try runGit(["add", ".gitignore", "tracked.txt"], in: repositoryURL)
        try runGit(["commit", "-m", "Initial commit"], in: repositoryURL)
        return repositoryURL
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ contents: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_AUTHOR_NAME": "Open Assist Tests",
            "GIT_AUTHOR_EMAIL": "openassist-tests@local.invalid",
            "GIT_COMMITTER_NAME": "Open Assist Tests",
            "GIT_COMMITTER_EMAIL": "openassist-tests@local.invalid"
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutText = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw XCTSkip("Git command failed: git \(arguments.joined(separator: " "))\n\(stderrText)\n\(stdoutText)")
        }
        return stdoutText
    }
}
