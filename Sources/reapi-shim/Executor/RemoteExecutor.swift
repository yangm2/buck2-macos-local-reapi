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
    private let remote: any RemoteREAPIBackend

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
        remote = LiveRemoteREAPIBackend(grpcClient: client)
        logger.info("remote executor → \(host, privacy: .public):\(port)")
    }

    /// Test-only initialiser — skips network setup, injects a mock backend.
    init(localCAS: ContentAddressableStorage, remote: any RemoteREAPIBackend) {
        self.localCAS = localCAS
        self.remote = remote
    }

    // MARK: - ActionExecutor

    func execute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        let allDigests = try await Self.collectDigests(for: actionDigest, cas: localCAS)
        let missing = try await remote.findMissingBlobs(allDigests)
        if !missing.isEmpty {
            var entries: [(Build_Bazel_Remote_Execution_V2_Digest, Data)] = []
            for digest in missing {
                try await entries.append((digest, localCAS.fetch(digest)))
            }
            try await remote.batchUpdateBlobs(entries)
        }
        return try await remote.execute(actionDigest: actionDigest, skipCacheLookup: skipCacheLookup)
    }

    // MARK: - Digest collection

    /// Walks the action's Directory tree and collects all referenced digests.
    static func collectDigests(
        for actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        cas: ContentAddressableStorage
    ) async throws -> [Build_Bazel_Remote_Execution_V2_Digest] {
        var digests: [Build_Bazel_Remote_Execution_V2_Digest] = [actionDigest]
        let actionData = try await cas.fetch(actionDigest)
        let action = try Build_Bazel_Remote_Execution_V2_Action(serializedBytes: actionData)
        digests.append(action.commandDigest)
        try await collectDirectoryDigests(action.inputRootDigest, into: &digests, cas: cas)
        return digests
    }

    static func collectDirectoryDigests(
        _ digest: Build_Bazel_Remote_Execution_V2_Digest,
        into digests: inout [Build_Bazel_Remote_Execution_V2_Digest],
        cas: ContentAddressableStorage
    ) async throws {
        digests.append(digest)
        let data = try await cas.fetch(digest)
        let dir = try Build_Bazel_Remote_Execution_V2_Directory(serializedBytes: data)
        for file in dir.files {
            digests.append(file.digest)
        }
        for subdir in dir.directories {
            try await collectDirectoryDigests(subdir.digest, into: &digests, cas: cas)
        }
    }

    // MARK: - Execute response parsing

    /// Unpacks the ``ActionResult`` from an Execute streaming response.
    static func extractResult(
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
