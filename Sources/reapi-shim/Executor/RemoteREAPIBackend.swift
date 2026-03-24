import Foundation
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
