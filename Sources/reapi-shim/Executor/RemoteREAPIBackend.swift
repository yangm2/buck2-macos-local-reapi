import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

// MARK: - RemoteREAPIBackend

/// Abstracts the remote gRPC calls that ``RemoteExecutor`` makes.
///
/// The live implementation talks to a real REAPI endpoint via gRPC/HTTP2.
/// Tests supply a mock that drives deterministic behaviour without a network.
protocol RemoteREAPIBackend: Sendable {
    /// Returns the subset of `digests` that are absent from the remote CAS.
    func findMissingBlobs(
        _ digests: [Build_Bazel_Remote_Execution_V2_Digest]
    ) async throws -> [Build_Bazel_Remote_Execution_V2_Digest]

    /// Uploads blobs to the remote CAS.
    func batchUpdateBlobs(
        _ entries: [(Build_Bazel_Remote_Execution_V2_Digest, Data)]
    ) async throws

    /// Forwards an Execute call and returns the final ``ActionResult``.
    func execute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult
}

// MARK: - LiveRemoteREAPIBackend

/// Production ``RemoteREAPIBackend`` backed by a live REAPI endpoint over gRPC.
///
/// Owns the gRPC connection lifecycle: the client is shut down and the
/// connection task cancelled when this object is deallocated.
final class LiveRemoteREAPIBackend: RemoteREAPIBackend, @unchecked Sendable {
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let runTask: Task<Void, Error>

    init(grpcClient: GRPCClient<HTTP2ClientTransport.Posix>) {
        self.grpcClient = grpcClient
        runTask = Task { try await grpcClient.runConnections() }
    }

    deinit {
        grpcClient.beginGracefulShutdown()
        runTask.cancel()
    }

    func findMissingBlobs(
        _ digests: [Build_Bazel_Remote_Execution_V2_Digest]
    ) async throws -> [Build_Bazel_Remote_Execution_V2_Digest] {
        let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage
            .Client(wrapping: grpcClient)
        var req = Build_Bazel_Remote_Execution_V2_FindMissingBlobsRequest()
        req.blobDigests = digests
        let resp = try await casClient.findMissingBlobs(request: .init(message: req))
        return resp.missingBlobDigests
    }

    func batchUpdateBlobs(
        _ entries: [(Build_Bazel_Remote_Execution_V2_Digest, Data)]
    ) async throws {
        let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage
            .Client(wrapping: grpcClient)
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
