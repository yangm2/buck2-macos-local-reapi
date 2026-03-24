import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import OSLog
import SwiftProtobuf

private let logger = Logger(subsystem: "dev.reapi-shim", category: "RemoteExecutor")

enum RemoteExecutorError: Error, CustomStringConvertible {
    case invalidEndpoint(String)
    case streamEndedWithoutResult
    case executeFailed(code: Int32, message: String)

    var description: String {
        switch self {
        case let .invalidEndpoint(url):
            "invalid remote endpoint URL: \(url)"
        case .streamEndedWithoutResult:
            "Execute stream ended before a done=true Operation"
        case let .executeFailed(code, message):
            "remote execution failed (code=\(code)): \(message)"
        }
    }
}

/// Forwards REAPI actions to an upstream REAPI endpoint.
///
/// Before forwarding an Execute call, all blobs referenced by the action
/// that are absent from the remote CAS are uploaded via `BatchUpdateBlobs`.
/// This ensures the remote worker can find its inputs without shared storage.
///
/// The endpoint URL scheme controls transport security:
/// - `grpc://`  — plaintext
/// - `grpcs://` — TLS with system root certificates
actor RemoteExecutor: ActionExecutor {
    private let localCAS: ContentAddressableStorage
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let runTask: Task<Void, Error>

    init(localCAS: ContentAddressableStorage, endpoint: String) throws {
        guard let url = URL(string: endpoint),
              let host = url.host,
              let port = url.port
        else { throw RemoteExecutorError.invalidEndpoint(endpoint) }
        let security: HTTP2ClientTransport.Posix.TransportSecurity =
            url.scheme == "grpcs" ? .tls : .plaintext
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: security
        )
        let client = GRPCClient(transport: transport)
        self.localCAS = localCAS
        grpcClient = client
        runTask = Task { try await client.runConnections() }
        logger.info("remote executor → \(host, privacy: .public):\(port)")
    }

    deinit {
        grpcClient.beginGracefulShutdown()
        runTask.cancel()
    }

    // MARK: - ActionExecutor

    func execute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        try await uploadMissingBlobs(for: actionDigest)
        return try await forwardExecute(
            actionDigest: actionDigest,
            skipCacheLookup: skipCacheLookup
        )
    }

    // MARK: - CAS forwarding

    /// Ensures the remote CAS has every blob required by the action.
    private func uploadMissingBlobs(
        for actionDigest: Build_Bazel_Remote_Execution_V2_Digest
    ) async throws {
        let allDigests = try await collectDigests(for: actionDigest)
        let casClient = Build_Bazel_Remote_Execution_V2_ContentAddressableStorage
            .Client(wrapping: grpcClient)
        var findReq = Build_Bazel_Remote_Execution_V2_FindMissingBlobsRequest()
        findReq.blobDigests = allDigests
        let findResp = try await casClient.findMissingBlobs(request: .init(message: findReq))
        guard !findResp.missingBlobDigests.isEmpty else { return }
        var updateReq = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest()
        for digest in findResp.missingBlobDigests {
            var entry = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest.Request()
            entry.digest = digest
            entry.data = try await localCAS.fetch(digest)
            updateReq.requests.append(entry)
        }
        _ = try await casClient.batchUpdateBlobs(request: .init(message: updateReq))
    }

    /// Walks the action's Directory tree and collects all referenced digests.
    private func collectDigests(
        for actionDigest: Build_Bazel_Remote_Execution_V2_Digest
    ) async throws -> [Build_Bazel_Remote_Execution_V2_Digest] {
        var digests: [Build_Bazel_Remote_Execution_V2_Digest] = [actionDigest]
        let actionData = try await localCAS.fetch(actionDigest)
        let action = try Build_Bazel_Remote_Execution_V2_Action(serializedBytes: actionData)
        digests.append(action.commandDigest)
        try await collectDirectoryDigests(action.inputRootDigest, into: &digests)
        return digests
    }

    private func collectDirectoryDigests(
        _ digest: Build_Bazel_Remote_Execution_V2_Digest,
        into digests: inout [Build_Bazel_Remote_Execution_V2_Digest]
    ) async throws {
        digests.append(digest)
        let data = try await localCAS.fetch(digest)
        let dir = try Build_Bazel_Remote_Execution_V2_Directory(serializedBytes: data)
        for file in dir.files {
            digests.append(file.digest)
        }
        for subdir in dir.directories {
            try await collectDirectoryDigests(subdir.digest, into: &digests)
        }
    }

    // MARK: - Execute forwarding

    private func forwardExecute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        let execClient = Build_Bazel_Remote_Execution_V2_Execution.Client(wrapping: grpcClient)
        var req = Build_Bazel_Remote_Execution_V2_ExecuteRequest()
        req.actionDigest = actionDigest
        req.skipCacheLookup = skipCacheLookup
        return try await execClient.execute(request: .init(message: req)) { response in
            try await Self.extractResult(from: response)
        }
    }

    private static func extractResult(
        from response: GRPCCore.StreamingClientResponse<Google_Longrunning_Operation>
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        for try await operation in response.messages {
            guard operation.done else { continue }
            switch operation.result {
            case let .error(status):
                throw RemoteExecutorError.executeFailed(
                    code: status.code, message: status.message
                )
            case let .response(any):
                let execResp = try Build_Bazel_Remote_Execution_V2_ExecuteResponse(
                    unpackingAny: any
                )
                return execResp.result
            case nil:
                break
            }
        }
        throw RemoteExecutorError.streamEndedWithoutResult
    }
}
