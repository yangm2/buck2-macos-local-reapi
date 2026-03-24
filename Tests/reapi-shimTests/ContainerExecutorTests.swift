import ContainerizationOCI
import ContainerResource
import Foundation
@testable import reapi_shim
import SwiftProtobuf
import Testing

// MARK: - Fixture helpers

private func makeTempCAS() throws -> ContentAddressableStorage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("executor-test-cas-\(UUID().uuidString)")
    return try ContentAddressableStorage(rootURL: url)
}

private func makeTempCache() throws -> ActionCache {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("executor-test-cache-\(UUID().uuidString)")
    return try ActionCache(rootURL: url)
}

/// Stores an empty-input-tree Command and Action in CAS; returns the action digest.
private func storeMinimalAction(
    in cas: ContentAddressableStorage,
    args: [String] = ["/bin/echo"],
    outputPaths: [String] = []
) async throws -> Build_Bazel_Remote_Execution_V2_Digest {
    let rootDigest = try await cas.store(
        Build_Bazel_Remote_Execution_V2_Directory().serializedData()
    )
    var cmd = Build_Bazel_Remote_Execution_V2_Command()
    cmd.arguments = args
    cmd.outputPaths = outputPaths
    let cmdDigest = try await cas.store(cmd.serializedData())
    var action = Build_Bazel_Remote_Execution_V2_Action()
    action.commandDigest = cmdDigest
    action.inputRootDigest = rootDigest
    return try await cas.store(action.serializedData())
}

private func makeImageDescription() -> ImageDescription {
    ImageDescription(
        reference: "test-image:latest",
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:\(String(repeating: "a", count: 64))",
            size: 1
        )
    )
}

// MARK: - MockContainerProcess

/// Simulates the daemon's side of a pipe: writes mock output and closes its fd copies on wait().
private struct MockContainerProcess: ContainerProcess {
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle
    let mockStdout: Data
    let mockStderr: Data
    let exitCode: Int32

    func start() async throws {}

    func wait() async throws -> Int32 {
        try? stdoutHandle.write(contentsOf: mockStdout)
        try? stderrHandle.write(contentsOf: mockStderr)
        try? stdoutHandle.close()
        try? stderrHandle.close()
        return exitCode
    }

    func kill(_: Int32) async throws {}
}

// MARK: - MockContainerBackend

private actor MockContainerBackend: ContainerBackend {
    private(set) var resolveImageCallCount = 0
    private(set) var createCallCount = 0
    private(set) var deleteCallCount = 0

    private let exitCode: Int32
    private let mockStdout: Data
    private let mockStderr: Data
    private let memoryBytes: UInt64?

    init(
        exitCode: Int32 = 0,
        stdout: Data = Data(),
        stderr: Data = Data(),
        memoryBytes: UInt64? = nil
    ) {
        self.exitCode = exitCode
        mockStdout = stdout
        mockStderr = stderr
        self.memoryBytes = memoryBytes
    }

    func resolveImage(_: String) async throws -> ImageDescription {
        resolveImageCallCount += 1
        return makeImageDescription()
    }

    func create(id _: String, config _: ContainerConfiguration) async throws {
        createCallCount += 1
    }

    func bootstrap(
        id _: String,
        stdout: FileHandle,
        stderr: FileHandle
    ) async throws -> any ContainerProcess {
        // dup() gives the mock independent fds unaffected by the executor's close()
        let outFd = dup(stdout.fileDescriptor)
        let errFd = dup(stderr.fileDescriptor)
        return MockContainerProcess(
            stdoutHandle: FileHandle(fileDescriptor: outFd, closeOnDealloc: true),
            stderrHandle: FileHandle(fileDescriptor: errFd, closeOnDealloc: true),
            mockStdout: mockStdout,
            mockStderr: mockStderr,
            exitCode: exitCode
        )
    }

    func stats(id: String) async throws -> ContainerStats {
        ContainerStats(
            id: id, memoryUsageBytes: memoryBytes, memoryLimitBytes: nil,
            cpuUsageUsec: nil, networkRxBytes: nil, networkTxBytes: nil,
            blockReadBytes: nil, blockWriteBytes: nil, numProcesses: nil
        )
    }

    func delete(id _: String) async throws {
        deleteCallCount += 1
    }
}

// MARK: - ContainerExecutorTests

struct ContainerExecutorTests {
    private func makeExecutor(
        cas: ContentAddressableStorage,
        cache: ActionCache,
        backend: any ContainerBackend,
        keepFailed: Bool = false
    ) -> ContainerExecutor {
        ContainerExecutor(
            cas: cas,
            actionCache: cache,
            toolchainImage: "test:latest",
            keepFailedStaging: keepFailed,
            backend: backend
        )
    }

    @Test("Cache hit returns cached result without invoking backend")
    func cacheHit() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend()
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)
        var preloaded = Build_Bazel_Remote_Execution_V2_ActionResult()
        preloaded.exitCode = 42
        await cache.put(actionDigest: digest, result: preloaded)

        let result = try await executor.execute(actionDigest: digest, skipCacheLookup: false)

        #expect(result.exitCode == 42)
        #expect(await backend.createCallCount == 0)
        #expect(await backend.resolveImageCallCount == 0)
    }

    @Test("Successful action (exit 0) stores result in cache")
    func successfulActionCachesResult() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend(stdout: Data("hello\n".utf8))
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)

        let result = try await executor.execute(actionDigest: digest, skipCacheLookup: true)

        #expect(result.exitCode == 0)
        #expect(result.outputFiles.isEmpty)
        #expect(await cache.get(actionDigest: digest) != nil)
        #expect(await backend.createCallCount == 1)
    }

    @Test("Failed action (exit 1) is not cached and stderr has [HERMETIC] tag")
    func failedActionNotCachedAndClassified() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend(exitCode: 1)
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)

        let result = try await executor.execute(actionDigest: digest, skipCacheLookup: true)

        #expect(result.exitCode == 1)
        #expect(await cache.get(actionDigest: digest) == nil)
        let stderrText = try await stderrString(from: result, cas: cas)
        #expect(stderrText.contains("[HERMETIC]"))
    }

    @Test("OOM action (exit 137) stderr has [FLAKY] tag")
    func oomActionHasFlakyTag() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend(exitCode: 137)
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)

        let result = try await executor.execute(actionDigest: digest, skipCacheLookup: true)

        #expect(result.exitCode == 137)
        let stderrText = try await stderrString(from: result, cas: cas)
        #expect(stderrText.contains("[FLAKY]"))
    }

    @Test("skipCacheLookup=true bypasses a populated cache")
    func skipCacheLookupBypassesCache() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend()
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)
        var preloaded = Build_Bazel_Remote_Execution_V2_ActionResult()
        preloaded.exitCode = 99
        await cache.put(actionDigest: digest, result: preloaded)

        // skipCacheLookup: true forces execution regardless of the cached entry
        let result = try await executor.execute(actionDigest: digest, skipCacheLookup: true)

        #expect(result.exitCode == 0) // mock returns 0, not the cached 99
        #expect(await backend.createCallCount == 1)
    }

    @Test("resolveImage is called once per container execution")
    func resolveImageCalledPerExecution() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend()
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)

        _ = try await executor.execute(actionDigest: digest, skipCacheLookup: true)
        _ = try await executor.execute(actionDigest: digest, skipCacheLookup: true)

        // Each execution creates one container; image caching is the backend's responsibility
        #expect(await backend.resolveImageCallCount == 2)
        #expect(await backend.createCallCount == 2)
    }

    @Test("Stdout written by the process is stored in the result")
    func stdoutStoredInResult() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let expected = Data("hello world\n".utf8)
        let backend = MockContainerBackend(stdout: expected)
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)

        let result = try await executor.execute(actionDigest: digest, skipCacheLookup: true)

        let stored = try await cas.fetch(result.stdoutDigest)
        #expect(stored == expected)
    }

    @Test("Container is deleted after a successful execution")
    func containerDeletedAfterSuccess() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend()
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)

        _ = try await executor.execute(actionDigest: digest, skipCacheLookup: true)
        // delete runs in a fire-and-forget Task inside the executor's defer block;
        // yield long enough for the scheduled work to complete.
        try await Task.sleep(for: .milliseconds(100))

        #expect(await backend.deleteCallCount == 1)
    }

    @Test("Container is deleted even when the action fails")
    func containerDeletedAfterFailure() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let backend = MockContainerBackend(exitCode: 1)
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)
        let digest = try await storeMinimalAction(in: cas)

        _ = try await executor.execute(actionDigest: digest, skipCacheLookup: true)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await backend.deleteCallCount == 1)
    }

    @Test("Output files declared in the command are collected from the staging directory")
    func outputFilesCollected() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()

        // Build an input root that contains out.txt so InputStager stages it.
        let fileData = Data("result data".utf8)
        let fileDigest = try await cas.store(fileData)
        var fileNode = Build_Bazel_Remote_Execution_V2_FileNode()
        fileNode.name = "out.txt"
        fileNode.digest = fileDigest
        var rootDir = Build_Bazel_Remote_Execution_V2_Directory()
        rootDir.files = [fileNode]
        let rootDigest = try await cas.store(rootDir.serializedData())

        var cmd = Build_Bazel_Remote_Execution_V2_Command()
        cmd.arguments = ["/bin/echo"]
        cmd.outputPaths = ["out.txt"]
        let cmdDigest = try await cas.store(cmd.serializedData())

        var action = Build_Bazel_Remote_Execution_V2_Action()
        action.commandDigest = cmdDigest
        action.inputRootDigest = rootDigest
        let actionDigest = try await cas.store(action.serializedData())

        let backend = MockContainerBackend()
        let executor = makeExecutor(cas: cas, cache: cache, backend: backend)

        let result = try await executor.execute(actionDigest: actionDigest, skipCacheLookup: true)

        #expect(result.outputFiles.count == 1)
        #expect(result.outputFiles[0].path == "out.txt")
    }
}

// MARK: - Helpers

private func stderrString(
    from result: Build_Bazel_Remote_Execution_V2_ActionResult,
    cas: ContentAddressableStorage
) async throws -> String {
    let data = try await cas.fetch(result.stderrDigest)
    return String(data: data, encoding: .utf8) ?? ""
}
