import Foundation
import GRPCCore
import GRPCInProcessTransport
@testable import reapi_shim
import Testing

// MARK: - Test infrastructure

private func makeTempCAS() throws -> ContentAddressableStorage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("integration-test-\(UUID().uuidString)")
    return try ContentAddressableStorage(rootURL: url)
}

private func makeTempCache() throws -> ActionCache {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ac-integration-test-\(UUID().uuidString)")
    return try ActionCache(rootURL: url)
}

/// Builds a digest with a padded hash for use in tests.
private func makeTestDigest(_ hash: String, size: Int64 = 42) -> Build_Bazel_Remote_Execution_V2_Digest {
    var digest = Build_Bazel_Remote_Execution_V2_Digest()
    digest.hash = String(hash.prefix(64).padding(toLength: 64, withPad: "0", startingAt: 0))
    digest.sizeBytes = size
    return digest
}

/// Runs `body` with an in-process REAPI server backed by `cas` and `cache`.
///
/// The server and client are started in background tasks and shut down
/// gracefully once the body returns (or throws). No network socket is used —
/// communication goes through `InProcessTransport`.
private func withREAPIServer<T: Sendable>(
    cas: ContentAddressableStorage,
    cache: ActionCache,
    _ body: @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> T
) async throws -> T {
    let transport = InProcessTransport()
    let server = GRPCServer(
        transport: transport.server,
        services: [
            CapabilitiesService(),
            CASService(cas: cas),
            ActionCacheService(cache: cache)
        ]
    )
    let client = GRPCClient(transport: transport.client)

    return try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await server.serve() }
        group.addTask { try await client.runConnections() }

        defer {
            client.beginGracefulShutdown()
            server.beginGracefulShutdown()
        }

        return try await body(client)
    }
}

// MARK: - Capabilities service

struct CapabilitiesServiceIntegrationTests {
    @Test
    func `getCapabilities: SHA-256 is in supported digest functions`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let capClient = Build_Bazel_Remote_Execution_V2_Capabilities.Client(wrapping: grpcClient)
            let caps = try await capClient.getCapabilities(request: .init(message: .init()))
            #expect(caps.cacheCapabilities.digestFunctions.contains(.sha256))
        }
    }

    @Test
    func `getCapabilities: execution is enabled with SHA-256`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let capClient = Build_Bazel_Remote_Execution_V2_Capabilities.Client(wrapping: grpcClient)
            let caps = try await capClient.getCapabilities(request: .init(message: .init()))
            #expect(caps.executionCapabilities.execEnabled)
            #expect(caps.executionCapabilities.digestFunction == .sha256)
        }
    }

    @Test
    func `getCapabilities: ActionCache updates are enabled`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let capClient = Build_Bazel_Remote_Execution_V2_Capabilities.Client(wrapping: grpcClient)
            let caps = try await capClient.getCapabilities(request: .init(message: .init()))
            #expect(caps.cacheCapabilities.actionCacheUpdateCapabilities.updateEnabled)
        }
    }

    @Test
    func `getCapabilities: API version is 2.x`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let capClient = Build_Bazel_Remote_Execution_V2_Capabilities.Client(wrapping: grpcClient)
            let caps = try await capClient.getCapabilities(request: .init(message: .init()))
            #expect(caps.lowApiVersion.major == 2)
            #expect(caps.highApiVersion.major == 2)
        }
    }
}

// MARK: - CAS service

struct CASServiceIntegrationTests {
    @Test
    func `findMissingBlobs: unknown digest is reported as missing`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage.Client(
                wrapping: grpcClient
            )
            var request = Build_Bazel_Remote_Execution_V2_FindMissingBlobsRequest()
            request.blobDigests = [makeTestDigest("aaa")]
            let response = try await casClient.findMissingBlobs(request: .init(message: request))
            #expect(response.missingBlobDigests.count == 1)
        }
    }

    @Test
    func `findMissingBlobs: empty blob is never reported as missing (REAPI invariant)`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage.Client(
                wrapping: grpcClient
            )
            var emptyDigest = Build_Bazel_Remote_Execution_V2_Digest()
            emptyDigest.hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            emptyDigest.sizeBytes = 0
            var request = Build_Bazel_Remote_Execution_V2_FindMissingBlobsRequest()
            request.blobDigests = [emptyDigest]
            let response = try await casClient.findMissingBlobs(request: .init(message: request))
            #expect(response.missingBlobDigests.isEmpty, "empty blob must always be present")
        }
    }

    @Test
    func `batchUpdateBlobs + FindMissingBlobs: uploaded blob is no longer missing`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let payload = Data("integration test blob".utf8)
        let digest = ContentAddressableStorage.digest(for: payload)
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage.Client(
                wrapping: grpcClient
            )

            var updateEntry = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest.Request()
            updateEntry.digest = digest
            updateEntry.data = payload
            var updateRequest = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest()
            updateRequest.requests = [updateEntry]
            let updateResponse = try await casClient.batchUpdateBlobs(
                request: .init(message: updateRequest)
            )
            #expect(updateResponse.responses.first?.status.code == 0) // OK

            var findRequest = Build_Bazel_Remote_Execution_V2_FindMissingBlobsRequest()
            findRequest.blobDigests = [digest]
            let findResponse = try await casClient.findMissingBlobs(
                request: .init(message: findRequest)
            )
            #expect(findResponse.missingBlobDigests.isEmpty)
        }
    }

    @Test
    func `batchUpdateBlobs + BatchReadBlobs: round-trip preserves content`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let payload = Data("round-trip payload \(UUID().uuidString)".utf8)
        let digest = ContentAddressableStorage.digest(for: payload)
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage.Client(
                wrapping: grpcClient
            )

            var updateEntry = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest.Request()
            updateEntry.digest = digest
            updateEntry.data = payload
            var updateRequest = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest()
            updateRequest.requests = [updateEntry]
            _ = try await casClient.batchUpdateBlobs(request: .init(message: updateRequest))

            var readRequest = Build_Bazel_Remote_Execution_V2_BatchReadBlobsRequest()
            readRequest.digests = [digest]
            let readResponse = try await casClient.batchReadBlobs(
                request: .init(message: readRequest)
            )
            #expect(readResponse.responses.first?.data == payload)
            #expect(readResponse.responses.first?.status.code == 0) // OK
        }
    }

    @Test
    func `batchReadBlobs: absent blob returns NOT_FOUND status code`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage.Client(
                wrapping: grpcClient
            )
            var readRequest = Build_Bazel_Remote_Execution_V2_BatchReadBlobsRequest()
            readRequest.digests = [makeTestDigest("deadbeef")]
            let readResponse = try await casClient.batchReadBlobs(
                request: .init(message: readRequest)
            )
            #expect(readResponse.responses.first?.status.code == 5) // NOT_FOUND
        }
    }
}

// MARK: - ActionCache service

struct ActionCacheServiceIntegrationTests {
    @Test
    func `getActionResult: cache miss returns NOT_FOUND gRPC status`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let acClient = Build_Bazel_Remote_Execution_V2_ActionCache.Client(wrapping: grpcClient)
            var request = Build_Bazel_Remote_Execution_V2_GetActionResultRequest()
            request.actionDigest = makeTestDigest("notcached")
            do {
                _ = try await acClient.getActionResult(request: .init(message: request))
                Issue.record("Expected RPCError to be thrown for cache miss")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }
        }
    }

    @Test
    func `updateActionResult + GetActionResult: round-trip`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let actionDigest = makeTestDigest("abc123")
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let acClient = Build_Bazel_Remote_Execution_V2_ActionCache.Client(wrapping: grpcClient)

            var actionResult = Build_Bazel_Remote_Execution_V2_ActionResult()
            actionResult.exitCode = 0
            var updateRequest = Build_Bazel_Remote_Execution_V2_UpdateActionResultRequest()
            updateRequest.actionDigest = actionDigest
            updateRequest.actionResult = actionResult
            _ = try await acClient.updateActionResult(request: .init(message: updateRequest))

            var getRequest = Build_Bazel_Remote_Execution_V2_GetActionResultRequest()
            getRequest.actionDigest = actionDigest
            let result = try await acClient.getActionResult(request: .init(message: getRequest))
            #expect(result.exitCode == 0)
        }
    }

    @Test
    func `updateActionResult: exit code is preserved`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let actionDigest = makeTestDigest("exit42")
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let acClient = Build_Bazel_Remote_Execution_V2_ActionCache.Client(wrapping: grpcClient)

            var actionResult = Build_Bazel_Remote_Execution_V2_ActionResult()
            actionResult.exitCode = 42
            var updateRequest = Build_Bazel_Remote_Execution_V2_UpdateActionResultRequest()
            updateRequest.actionDigest = actionDigest
            updateRequest.actionResult = actionResult
            _ = try await acClient.updateActionResult(request: .init(message: updateRequest))

            var getRequest = Build_Bazel_Remote_Execution_V2_GetActionResultRequest()
            getRequest.actionDigest = actionDigest
            let result = try await acClient.getActionResult(request: .init(message: getRequest))
            #expect(result.exitCode == 42)
        }
    }

    @Test
    func `actionCache: different digests are stored independently`() async throws {
        let cas = try makeTempCAS()
        let cache = try makeTempCache()
        let digest1 = makeTestDigest("action111")
        let digest2 = makeTestDigest("action222")
        try await withREAPIServer(cas: cas, cache: cache) { grpcClient in
            let acClient = Build_Bazel_Remote_Execution_V2_ActionCache.Client(wrapping: grpcClient)

            for (actionDigest, exitCode) in [(digest1, Int32(1)), (digest2, Int32(2))] {
                var actionResult = Build_Bazel_Remote_Execution_V2_ActionResult()
                actionResult.exitCode = exitCode
                var updateRequest = Build_Bazel_Remote_Execution_V2_UpdateActionResultRequest()
                updateRequest.actionDigest = actionDigest
                updateRequest.actionResult = actionResult
                _ = try await acClient.updateActionResult(request: .init(message: updateRequest))
            }

            var getRequest1 = Build_Bazel_Remote_Execution_V2_GetActionResultRequest()
            getRequest1.actionDigest = digest1
            var getRequest2 = Build_Bazel_Remote_Execution_V2_GetActionResultRequest()
            getRequest2.actionDigest = digest2
            let result1 = try await acClient.getActionResult(request: .init(message: getRequest1))
            let result2 = try await acClient.getActionResult(request: .init(message: getRequest2))
            #expect(result1.exitCode == 1)
            #expect(result2.exitCode == 2)
        }
    }
}
