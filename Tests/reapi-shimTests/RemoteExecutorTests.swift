import Foundation
import GRPCCore
@testable import reapi_shim
import SwiftProtobuf
import Testing

// MARK: - Fixture helpers

private func makeTempCAS() throws -> ContentAddressableStorage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-executor-test-cas-\(UUID().uuidString)")
    return try ContentAddressableStorage(rootURL: url)
}

private struct ActionTree {
    let action: Build_Bazel_Remote_Execution_V2_Digest
    let command: Build_Bazel_Remote_Execution_V2_Digest
    let root: Build_Bazel_Remote_Execution_V2_Digest
    let subdir: Build_Bazel_Remote_Execution_V2_Digest
    let file1: Build_Bazel_Remote_Execution_V2_Digest
    let file2: Build_Bazel_Remote_Execution_V2_Digest
}

/// Stores a file blob, a two-level directory tree, a Command, and an Action in `cas`.
private func buildActionTree(in cas: ContentAddressableStorage) async throws -> ActionTree {
    let file1Digest = try await cas.store(Data("file1".utf8))
    let file2Digest = try await cas.store(Data("file2".utf8))

    var subdirProto = Build_Bazel_Remote_Execution_V2_Directory()
    var subdirFile = Build_Bazel_Remote_Execution_V2_FileNode()
    subdirFile.name = "f2.txt"
    subdirFile.digest = file2Digest
    subdirProto.files = [subdirFile]
    let subdirDigest = try await cas.store(subdirProto.serializedData())

    var rootProto = Build_Bazel_Remote_Execution_V2_Directory()
    var rootFile = Build_Bazel_Remote_Execution_V2_FileNode()
    rootFile.name = "f1.txt"
    rootFile.digest = file1Digest
    var subdirNode = Build_Bazel_Remote_Execution_V2_DirectoryNode()
    subdirNode.name = "sub"
    subdirNode.digest = subdirDigest
    rootProto.files = [rootFile]
    rootProto.directories = [subdirNode]
    let rootDigest = try await cas.store(rootProto.serializedData())

    var cmd = Build_Bazel_Remote_Execution_V2_Command()
    cmd.arguments = ["/bin/echo"]
    let cmdDigest = try await cas.store(cmd.serializedData())

    var action = Build_Bazel_Remote_Execution_V2_Action()
    action.commandDigest = cmdDigest
    action.inputRootDigest = rootDigest
    let actionDigest = try await cas.store(action.serializedData())

    return ActionTree(
        action: actionDigest,
        command: cmdDigest,
        root: rootDigest,
        subdir: subdirDigest,
        file1: file1Digest,
        file2: file2Digest
    )
}

// MARK: - StreamingClientResponse helpers

private typealias LROp = Google_Longrunning_Operation
private typealias BodyPart = StreamingClientResponse<LROp>.Contents.BodyPart

private func streamingResponse(_ operations: LROp...) -> StreamingClientResponse<LROp> {
    let ops = operations
    let stream = AsyncThrowingStream<BodyPart, any Error> { continuation in
        for oper in ops {
            continuation.yield(.message(oper))
        }
        continuation.yield(.trailingMetadata([:]))
        continuation.finish()
    }
    return StreamingClientResponse(
        of: LROp.self,
        metadata: [:],
        bodyParts: RPCAsyncSequence(wrapping: stream)
    )
}

private func successOperation(exitCode: Int32 = 0) throws -> LROp {
    var result = Build_Bazel_Remote_Execution_V2_ActionResult()
    result.exitCode = exitCode
    var execResp = Build_Bazel_Remote_Execution_V2_ExecuteResponse()
    execResp.result = result
    var oper = LROp()
    oper.done = true
    oper.result = try .response(Google_Protobuf_Any(message: execResp))
    return oper
}

private func errorOperation(code: Int32, message: String) -> LROp {
    var status = Google_Rpc_Status()
    status.code = code
    status.message = message
    var oper = LROp()
    oper.done = true
    oper.result = .error(status)
    return oper
}

private func pendingOperation() -> LROp {
    var oper = LROp()
    oper.done = false
    return oper
}

// MARK: - MockRemoteREAPIBackend

private actor MockRemoteREAPIBackend: RemoteREAPIBackend {
    private(set) var findCallCount = 0
    private(set) var uploadCallCount = 0
    private(set) var executeCallCount = 0
    private(set) var uploadedDigests: [Build_Bazel_Remote_Execution_V2_Digest] = []
    private(set) var lastSkipCacheLookup: Bool = false

    let missingDigests: [Build_Bazel_Remote_Execution_V2_Digest]
    let mockResult: Build_Bazel_Remote_Execution_V2_ActionResult

    init(
        missingDigests: [Build_Bazel_Remote_Execution_V2_Digest] = [],
        exitCode: Int32 = 0
    ) {
        self.missingDigests = missingDigests
        var result = Build_Bazel_Remote_Execution_V2_ActionResult()
        result.exitCode = exitCode
        mockResult = result
    }

    func findMissingBlobs(
        _: [Build_Bazel_Remote_Execution_V2_Digest]
    ) async throws -> [Build_Bazel_Remote_Execution_V2_Digest] {
        findCallCount += 1
        return missingDigests
    }

    func batchUpdateBlobs(
        _ entries: [(Build_Bazel_Remote_Execution_V2_Digest, Data)]
    ) async throws {
        uploadCallCount += 1
        uploadedDigests.append(contentsOf: entries.map(\.0))
    }

    func execute(
        actionDigest _: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        executeCallCount += 1
        lastSkipCacheLookup = skipCacheLookup
        return mockResult
    }
}

// MARK: - Digest collection tests

struct RemoteExecutorDigestTests {
    @Test
    func `collectDigests includes action, command, root dir, and file blobs`() async throws {
        let cas = try makeTempCAS()
        let tree = try await buildActionTree(in: cas)

        let digests = try await RemoteExecutor.collectDigests(for: tree.action, cas: cas)

        #expect(digests.contains(tree.action))
        #expect(digests.contains(tree.command))
        #expect(digests.contains(tree.root))
        #expect(digests.contains(tree.file1))
    }

    @Test
    func `collectDigests recurses into subdirectories`() async throws {
        let cas = try makeTempCAS()
        let tree = try await buildActionTree(in: cas)

        let digests = try await RemoteExecutor.collectDigests(for: tree.action, cas: cas)

        #expect(digests.contains(tree.subdir))
        #expect(digests.contains(tree.file2))
    }

    @Test
    func `collectDigests result has no duplicates for each blob category`() async throws {
        let cas = try makeTempCAS()
        let tree = try await buildActionTree(in: cas)

        let digests = try await RemoteExecutor.collectDigests(for: tree.action, cas: cas)
        let actionCount = digests.count(where: { $0 == tree.action })

        #expect(actionCount == 1)
    }
}

// MARK: - extractResult tests

struct RemoteExecutorExtractResultTests {
    @Test
    func `success operation returns ActionResult with correct exit code`() async throws {
        let oper = try successOperation(exitCode: 42)
        let response = streamingResponse(oper)

        let result = try await RemoteExecutor.extractResult(from: response)

        #expect(result.exitCode == 42)
    }

    @Test
    func `error operation throws executeFailed with code and message`() async throws {
        let oper = errorOperation(code: 9, message: "infra failure")
        let response = streamingResponse(oper)

        do {
            _ = try await RemoteExecutor.extractResult(from: response)
            Issue.record("Expected executeFailed to be thrown")
        } catch let RemoteExecutorError.executeFailed(code, message) {
            #expect(code == 9)
            #expect(message == "infra failure")
        }
    }

    @Test
    func `stream ending without done=true throws streamEndedWithoutResult`() async throws {
        let response = streamingResponse(pendingOperation())

        do {
            _ = try await RemoteExecutor.extractResult(from: response)
            Issue.record("Expected streamEndedWithoutResult to be thrown")
        } catch RemoteExecutorError.streamEndedWithoutResult {
            // expected
        }
    }

    @Test
    func `empty stream throws streamEndedWithoutResult`() async throws {
        let response = streamingResponse()

        do {
            _ = try await RemoteExecutor.extractResult(from: response)
            Issue.record("Expected streamEndedWithoutResult to be thrown")
        } catch RemoteExecutorError.streamEndedWithoutResult {
            // expected
        }
    }

    @Test
    func `not-done operations are skipped; first done=true operation wins`() async throws {
        let pending = pendingOperation()
        let done = try successOperation(exitCode: 7)
        let response = streamingResponse(pending, done)

        let result = try await RemoteExecutor.extractResult(from: response)

        #expect(result.exitCode == 7)
    }
}

// MARK: - RemoteExecutor integration tests (mock backend)

struct RemoteExecutorIntegrationTests {
    private func makeExecutor(
        cas: ContentAddressableStorage,
        backend: any RemoteREAPIBackend
    ) -> RemoteExecutor {
        RemoteExecutor(localCAS: cas, remote: backend)
    }

    @Test
    func `no blobs uploaded when remote already has all blobs`() async throws {
        let cas = try makeTempCAS()
        let tree = try await buildActionTree(in: cas)
        let backend = MockRemoteREAPIBackend() // reports nothing missing
        let executor = makeExecutor(cas: cas, backend: backend)

        _ = try await executor.execute(actionDigest: tree.action, skipCacheLookup: true)

        #expect(await backend.findCallCount == 1)
        #expect(await backend.uploadCallCount == 0)
    }

    @Test
    func `missing blobs are fetched from local CAS and uploaded`() async throws {
        let cas = try makeTempCAS()
        let tree = try await buildActionTree(in: cas)
        let backend = MockRemoteREAPIBackend(missingDigests: [tree.file1, tree.file2])
        let executor = makeExecutor(cas: cas, backend: backend)

        _ = try await executor.execute(actionDigest: tree.action, skipCacheLookup: true)

        #expect(await backend.uploadCallCount == 1)
        let uploaded = await backend.uploadedDigests
        #expect(uploaded.contains(tree.file1))
        #expect(uploaded.contains(tree.file2))
    }

    @Test
    func `execute is called with skipCacheLookup forwarded correctly`() async throws {
        let cas = try makeTempCAS()
        let tree = try await buildActionTree(in: cas)
        let backend = MockRemoteREAPIBackend()
        let executor = makeExecutor(cas: cas, backend: backend)

        _ = try await executor.execute(actionDigest: tree.action, skipCacheLookup: true)

        #expect(await backend.lastSkipCacheLookup == true)
        #expect(await backend.executeCallCount == 1)
    }

    @Test
    func `actionResult from remote backend is returned to caller`() async throws {
        let cas = try makeTempCAS()
        let tree = try await buildActionTree(in: cas)
        let backend = MockRemoteREAPIBackend(exitCode: 5)
        let executor = makeExecutor(cas: cas, backend: backend)

        let result = try await executor.execute(actionDigest: tree.action, skipCacheLookup: true)

        #expect(result.exitCode == 5)
    }
}
