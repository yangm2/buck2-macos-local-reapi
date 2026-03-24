import Darwin
import Foundation
import OSLog
import SwiftProtobuf

private let logger = Logger(subsystem: "dev.reapi-shim", category: "Executor")

/// Executes REAPI actions inside ephemeral Apple Container VMs.
///
/// Each action follows the lifecycle: stage inputs → launch container → capture outputs →
/// destroy container. The actor serialises execution so only one VM runs at a time,
/// which is the correct constraint for an 8 GB MacBook Pro (Phase 1).
actor ContainerExecutor {
    let cas: ContentAddressableStorage
    let actionCache: ActionCache
    let toolchainImage: String
    let containerPath: String
    let keepFailedStaging: Bool

    private let stagingBaseURL: URL
    private let profileStore = ResourceProfileStore()
    private var actionCounter = 0

    init(
        cas: ContentAddressableStorage,
        actionCache: ActionCache,
        toolchainImage: String,
        containerPath: String = "/usr/local/bin/container",
        keepFailedStaging: Bool = false
    ) {
        self.cas = cas
        self.actionCache = actionCache
        self.toolchainImage = toolchainImage
        self.containerPath = containerPath
        self.keepFailedStaging = keepFailedStaging
        stagingBaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reapi-shim-staging")
    }

    // MARK: - Execute

    func execute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        // 1. Check action cache
        if !skipCacheLookup, let cached = await actionCache.get(actionDigest: actionDigest) {
            return cached
        }

        // 2. Deserialise Action and Command from CAS
        logger.debug("fetching action \(actionDigest.hash, privacy: .public):\(actionDigest.sizeBytes)")
        let actionData = try await cas.fetch(actionDigest)
        let action = try Build_Bazel_Remote_Execution_V2_Action(serializedBytes: actionData)

        logger.debug("fetching command \(action.commandDigest.hash, privacy: .public)")
        let commandData = try await cas.fetch(action.commandDigest)
        let command = try Build_Bazel_Remote_Execution_V2_Command(serializedBytes: commandData)

        // 3. Stage input root into a temporary directory
        actionCounter += 1
        let stagingDir = stagingBaseURL.appendingPathComponent(
            "\(actionDigest.hash.prefix(16))-\(actionCounter)"
        )
        var cleanupStaging = true
        defer {
            if cleanupStaging {
                try? FileManager.default.removeItem(at: stagingDir)
            }
        }

        let stager = InputStager(cas: cas)
        try await stager.stage(rootDigest: action.inputRootDigest, into: stagingDir)

        // 4. Determine container resource profile from prior observations
        let profile = await profileStore.profile(for: actionDigest.hash) ?? .conservative

        // 5. Run the container
        let runResult = try await runContainer(
            actionHash: actionDigest.hash,
            command: command,
            stagingDir: stagingDir,
            profile: profile
        )

        // Preserve staging directory on failure when requested
        if runResult.exitCode != 0, keepFailedStaging {
            cleanupStaging = false
            logger.info("staging preserved for post-mortem: \(stagingDir.path, privacy: .public)")
        }

        // 6. Collect outputs from the staging directory back into CAS
        let collector = OutputCollector(cas: cas)
        let outputPaths = command.outputPaths.isEmpty
            ? command.outputFiles + command.outputDirectories
            : command.outputPaths
        let outputFiles = try await collector.collect(
            outputPaths: outputPaths,
            workDir: stagingDir
        )

        // 7–8. Store stdout/stderr and assemble ActionResult
        let result = try await buildActionResult(runResult: runResult, outputFiles: outputFiles)

        // 9. Cache successful results (exit code 0 only)
        if runResult.exitCode == 0 {
            await actionCache.put(actionDigest: actionDigest, result: result)
        }

        return result
    }

    private func buildActionResult(
        runResult: RunResult,
        outputFiles: [Build_Bazel_Remote_Execution_V2_OutputFile]
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        let stdoutDigest = try await cas.store(runResult.stdout)
        let stderrDigest = try await cas.store(runResult.stderr)

        var result = Build_Bazel_Remote_Execution_V2_ActionResult()
        result.exitCode = runResult.exitCode
        result.outputFiles = outputFiles
        result.stdoutDigest = stdoutDigest
        result.stderrDigest = stderrDigest

        var meta = Build_Bazel_Remote_Execution_V2_ExecutedActionMetadata()
        meta.worker = "local-apple-container"
        result.executionMetadata = meta

        return result
    }

    // MARK: - Container invocation

    private struct RunResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Launches the toolchain container, waits for it to exit, records its
    /// resource usage, and returns stdout, stderr, and exit code.
    /// Stderr is passed through ``ErrorClassifier`` to rewrite container-internal
    /// paths and produce a human-readable message for non-zero exits.
    private func runContainer(
        actionHash: String,
        command: Build_Bazel_Remote_Execution_V2_Command,
        stagingDir: URL,
        profile: ActionProfile
    ) async throws -> RunResult {
        let args = buildContainerArgs(command: command, stagingDir: stagingDir, profile: profile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: containerPath)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let wallStart = Date()
        try process.run()

        // Async-friendly wait to avoid blocking the actor
        let stdout = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        await recordPostRunMetrics(hash: actionHash, wallStart: wallStart)

        // Rewrite container-internal paths and classify any failure
        var stderrString = String(data: stderr, encoding: .utf8) ?? ""
        stderrString = ErrorClassifier.rewritePaths(stderrString)

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let classified = ErrorClassifier.classify(
                exitCode: exitCode,
                signal: process.terminationReason == .uncaughtSignal ? Int32(exitCode) : nil,
                stderr: stderrString,
                memoryLimitMB: profile.memoryMB,
                containerError: nil
            )
            stderrString = ErrorClassifier.format(classified)
        }

        return RunResult(exitCode: exitCode, stdout: stdout, stderr: Data(stderrString.utf8))
    }

    /// Records wall time and peak RSS for the last exited child process.
    ///
    /// `ru_maxrss` via `RUSAGE_CHILDREN` is cumulative (maximum across all
    /// children that have exited since this process started), so the value
    /// converges toward the peak observed across all runs — acceptable for
    /// Phase 1 heuristics.
    private func recordPostRunMetrics(hash: String, wallStart: Date) async {
        let wallTimeSec = Date().timeIntervalSince(wallStart)
        var rusageStats = rusage()
        Darwin.getrusage(RUSAGE_CHILDREN, &rusageStats)
        // ru_maxrss is in bytes on macOS (unlike Linux where it is kibibytes)
        let peakMemoryMB = Int(rusageStats.ru_maxrss) / (1024 * 1024)
        let shortHash = hash.prefix(16)
        logger.debug("action \(shortHash, privacy: .public) wall=\(wallTimeSec)s rss=\(peakMemoryMB)MiB")
        await profileStore.record(hash: hash, memoryMB: peakMemoryMB, wallTimeSec: wallTimeSec)
    }

    /// Builds the argument list for `container run`.
    private func buildContainerArgs(
        command: Build_Bazel_Remote_Execution_V2_Command,
        stagingDir: URL,
        profile: ActionProfile
    ) -> [String] {
        var args = ["run", "--rm"]
        args += ["-m", "\(profile.memoryMB)m"]
        args += ["-c", "\(profile.cpus)"]
        args += ["--network", "none"]
        args += ["-v", "\(stagingDir.path):/workspace"]
        let workDir = command.workingDirectory.isEmpty
            ? "/workspace"
            : "/workspace/\(command.workingDirectory)"
        args += ["-w", workDir]
        for envVar in command.environmentVariables {
            args += ["-e", "\(envVar.name)=\(envVar.value)"]
        }
        args.append(toolchainImage)
        args += command.arguments
        return args
    }
}
