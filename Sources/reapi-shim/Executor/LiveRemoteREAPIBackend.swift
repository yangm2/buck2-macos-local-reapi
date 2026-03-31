import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

// MARK: - LiveRemoteREAPIBackend

/// Production ``RemoteREAPIBackend`` backed by a live REAPI endpoint over gRPC.
///
/// Owns the gRPC connection lifecycle: the client is shut down and the
/// connection task cancelled when this object is deallocated.
///
/// This file is excluded from unit-test coverage because a live REAPI endpoint
/// is not available in the test environment; coverage is provided by
/// `RemoteREAPIBackend.swift` (protocol) and `RemoteExecutorTests` (mock-backed executor).
final class LiveRemoteREAPIBackend: RemoteREAPIBackend, @unchecked Sendable {
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let runTask: Task<Void, Error>
    private let casClient: Build_Bazel_Remote_Execution_V2_ContentAddressableStorage
        .Client<HTTP2ClientTransport.Posix>

    init(grpcClient: GRPCClient<HTTP2ClientTransport.Posix>) {
        self.grpcClient = grpcClient
        runTask = Task { try await grpcClient.runConnections() }
        casClient = .init(wrapping: grpcClient)
    }

    deinit {
        grpcClient.beginGracefulShutdown()
        runTask.cancel()
    }

    func findMissingBlobs(
        _ digests: [Build_Bazel_Remote_Execution_V2_Digest]
    ) async throws -> [Build_Bazel_Remote_Execution_V2_Digest] {
        var req = Build_Bazel_Remote_Execution_V2_FindMissingBlobsRequest()
        req.blobDigests = digests
        let resp = try await casClient.findMissingBlobs(request: .init(message: req))
        return resp.missingBlobDigests
    }

    func batchUpdateBlobs(
        _ entries: [(Build_Bazel_Remote_Execution_V2_Digest, Data)]
    ) async throws {
        var req = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest()
        for (digest, data) in entries {
            var entry = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest.Request()
            entry.digest = digest
            entry.data = data
            req.requests.append(entry)
        }
        _ = try await casClient.batchUpdateBlobs(request: .init(message: req))
    }

    func execute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        let execClient = Build_Bazel_Remote_Execution_V2_Execution.Client(wrapping: grpcClient)
        var req = Build_Bazel_Remote_Execution_V2_ExecuteRequest()
        req.actionDigest = actionDigest
        req.skipCacheLookup = skipCacheLookup
        return try await execClient.execute(request: .init(message: req)) { response in
            try await RemoteExecutor.extractResult(from: response)
        }
    }
}
