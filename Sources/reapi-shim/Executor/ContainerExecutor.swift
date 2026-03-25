import ContainerResource
import Foundation
import OSLog
import SwiftProtobuf

private let logger = Logger(subsystem: "dev.reapi-shim", category: "Executor")

/// Executes REAPI actions inside ephemeral Apple Container VMs.
///
/// Each action follows the lifecycle: stage inputs → launch container → capture outputs →
/// destroy container. The actor serialises execution so only one VM runs at a time,
/// which is the correct constraint for an 8 GB MacBook Pro (Phase 1).
actor ContainerExecutor: ActionExecutor {
    let cas: ContentAddressableStorage
    let actionCache: ActionCache
    let toolchainImage: String
    let keepFailedStaging: Bool
    /// Extra path segments to prepend to `PATH` inside container actions.
    ///
    /// Useful when the build toolchain is installed in a non-standard prefix
    /// (e.g. `/nix/var/nix/profiles/default/bin`) that is absent from the
    /// hermetic PATH that Buck2 sends via the REAPI `Command` message.
    let pathPrefix: String?

    private let stagingBaseURL: URL
    private let profileStore = ResourceProfileStore()
    private var actionCounter = 0
    private let backend: any ContainerBackend

    init(
        cas: ContentAddressableStorage,
        actionCache: ActionCache,
        toolchainImage: String,
        keepFailedStaging: Bool = false,
        pathPrefix: String? = nil,
        backend: any ContainerBackend = LiveContainerBackend()
    ) {
        self.cas = cas
        self.actionCache = actionCache
        self.toolchainImage = toolchainImage
        self.keepFailedStaging = keepFailedStaging
        self.pathPrefix = pathPrefix
        self.backend = backend
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

        // 5. Resolve the image to use for this action.
        //    The `container-image` platform property (convention shared with BuildBuddy,
        //    BuildBarn, etc.) overrides the shim-level default.  Strip the `docker://`
        //    scheme prefix that some clients include (e.g. `docker://ubuntu:24.04`).
        let image = action.platform.properties
            .first { $0.name == "container-image" }
            .map { $0.value.hasPrefix("docker://") ? String($0.value.dropFirst(9)) : $0.value }
            ?? toolchainImage

        // 6. Run the container
        logger.debug("image for \(actionDigest.hash.prefix(16), privacy: .public): \(image, privacy: .public)")
        let runResult = try await runContainer(
            actionHash: actionDigest.hash,
            command: command,
            stagingDir: stagingDir,
            profile: profile,
            image: image
        )

        // Preserve staging directory on failure when requested
        if runResult.exitCode != 0, keepFailedStaging {
            cleanupStaging = false
            logger.info("staging preserved for post-mortem: \(stagingDir.path, privacy: .public)")
        }

        // 7. Collect outputs from the staging directory back into CAS
        let collector = OutputCollector(cas: cas)
        let outputPaths = command.outputPaths.isEmpty
            ? command.outputFiles + command.outputDirectories
            : command.outputPaths
        let outputFiles = try await collector.collect(
            outputPaths: outputPaths,
            workDir: stagingDir
        )

        // 8–9. Store stdout/stderr and assemble ActionResult
        let result = try await buildActionResult(runResult: runResult, outputFiles: outputFiles)

        // 10. Cache successful results (exit code 0 only)
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

    /// Launches a toolchain container via the container-apiserver daemon, waits for
    /// it to exit, records resource usage, and returns stdout, stderr, and exit code.
    ///
    /// The container is created with an empty `networks` array (hermetic — no
    /// network access) and a single VirtioFS mount exposing the action's staging
    /// directory as `/workspace` inside the VM.
    ///
    /// Stderr is passed through ``ErrorClassifier`` to rewrite container-internal
    /// paths and produce a human-readable message for non-zero exits.
    private func runContainer(
        actionHash: String,
        command: Build_Bazel_Remote_Execution_V2_Command,
        stagingDir: URL,
        profile: ActionProfile,
        image: String
    ) async throws -> RunResult {
        let containerId = "reapi-\(UUID().uuidString.lowercased().prefix(8))-\(actionHash.prefix(8))"
        let config = try await buildContainerConfig(
            containerId: containerId,
            command: command,
            stagingDir: stagingDir,
            profile: profile,
            image: image
        )

        let wallStart = Date()
        try await backend.create(id: containerId, config: config)
        defer { Task { try? await self.backend.delete(id: containerId) } }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try await backend.bootstrap(
            id: containerId,
            stdout: stdoutPipe.fileHandleForWriting,
            stderr: stderrPipe.fileHandleForWriting
        )
        try await process.start()

        // Close our copies of the write ends. The daemon holds its own copies via XPC
        // and will close them when the container process exits, signalling EOF to readers.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Drain I/O concurrently to prevent pipe-buffer deadlock while the process runs.
        // Use the throwing readToEnd() variant (macOS 10.15.4+) instead of the ObjC
        // readDataToEndOfFile(), which raises an uncatchable NSException on pipe errors
        // (e.g. broken pipe when the container exits abruptly).
        let stdoutTask = Task.detached { (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data() }
        let stderrTask = Task.detached { (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data() }

        // Poll memory stats concurrently every 250 ms; track peak usage.
        let capturedBackend = backend
        let statsTask = Task.detached { () -> Int in
            var peak = 0
            while !Task.isCancelled {
                let statsResult = try? await capturedBackend.stats(id: containerId)
                if let bytes = statsResult?.memoryUsageBytes {
                    peak = max(peak, Int(bytes / (1024 * 1024)))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return peak
        }

        let exitCode = try await process.wait()
        statsTask.cancel()
        let peakMemMB = await statsTask.value

        let wallTimeSec = Date().timeIntervalSince(wallStart)
        logger.debug("action \(actionHash.prefix(16), privacy: .public) wall=\(wallTimeSec)s rss=\(peakMemMB)MiB")
        await profileStore.record(hash: actionHash, memoryMB: peakMemMB, wallTimeSec: wallTimeSec)

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        return RunResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: classifyStderr(stderr, exitCode: exitCode, profile: profile)
        )
    }

    /// Builds the ``ContainerConfiguration`` for a single action run.
    ///
    /// The image is resolved (and cached) from the daemon on first call.
    /// Networks are intentionally left empty so the VM has no network access.
    private func buildContainerConfig(
        containerId: String,
        command: Build_Bazel_Remote_Execution_V2_Command,
        stagingDir: URL,
        profile: ActionProfile,
        image: String
    ) async throws -> ContainerConfiguration {
        let imageDescription = try await backend.resolveImage(image)
        let workDir = command.workingDirectory.isEmpty
            ? "/workspace"
            : "/workspace/\(command.workingDirectory)"
        var env = command.environmentVariables.map { "\($0.name)=\($0.value)" }
        if let prefix = pathPrefix {
            if let idx = env.firstIndex(where: { $0.hasPrefix("PATH=") }) {
                let current = String(env[idx].dropFirst("PATH=".count))
                env[idx] = "PATH=\(prefix):\(current)"
            } else {
                env.append("PATH=\(prefix):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            }
        }
        let processConfig = ProcessConfiguration(
            executable: command.arguments[0],
            arguments: Array(command.arguments.dropFirst()),
            environment: env,
            workingDirectory: workDir
        )
        var config = ContainerConfiguration(id: containerId, image: imageDescription, process: processConfig)
        var resources = ContainerConfiguration.Resources()
        resources.cpus = profile.cpus
        resources.memoryInBytes = UInt64(profile.memoryMB) * 1024 * 1024
        config.resources = resources
        config.mounts = [.virtiofs(source: stagingDir.path, destination: "/workspace", options: [])]
        return config
    }

    /// Rewrites container-internal paths and classifies non-zero exits.
    private func classifyStderr(_ raw: Data, exitCode: Int32, profile: ActionProfile) -> Data {
        var text = ErrorClassifier.rewritePaths(String(data: raw, encoding: .utf8) ?? "")
        if exitCode != 0 {
            // Exit code 137 = 128 + SIGKILL(9), indicating an OOM or forced termination.
            let classified = ErrorClassifier.classify(
                exitCode: exitCode,
                signal: exitCode == 137 ? 9 : nil,
                stderr: text,
                memoryLimitMB: profile.memoryMB,
                containerError: nil
            )
            text = ErrorClassifier.format(classified)
        }
        return Data(text.utf8)
    }
}
