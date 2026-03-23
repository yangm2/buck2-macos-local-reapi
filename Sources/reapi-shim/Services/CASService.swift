import GRPCCore
import GRPCProtobuf

/// REAPI `ContentAddressableStorage` service backed by the local filesystem CAS.
///
/// Implements `FindMissingBlobs`, `BatchUpdateBlobs`, and `BatchReadBlobs`.
/// `GetTree`, `SplitBlob`, and `SpliceBlob` are not used by Buck2 and are
/// stubbed or unimplemented accordingly.
struct CASService: Build_Bazel_Remote_Execution_V2_ContentAddressableStorage.SimpleServiceProtocol {
    let cas: ContentAddressableStorage

    func findMissingBlobs(
        request: Build_Bazel_Remote_Execution_V2_FindMissingBlobsRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_FindMissingBlobsResponse {
        let missing = await cas.findMissing(request.blobDigests)
        log("[CAS] findMissingBlobs: \(request.blobDigests.count) queried, \(missing.count) missing")
        var response = Build_Bazel_Remote_Execution_V2_FindMissingBlobsResponse()
        response.missingBlobDigests = missing
        return response
    }

    func batchUpdateBlobs(
        request: Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsResponse {
        log("[CAS] batchUpdateBlobs: \(request.requests.count) blobs")
        var responses: [Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsResponse.Response] = []
        for entry in request.requests {
            var resp = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsResponse.Response()
            resp.digest = entry.digest
            do {
                _ = try await cas.store(entry.data)
                resp.status = .success
            } catch {
                var errStatus = Google_Rpc_Status()
                errStatus.code = 13 // INTERNAL
                errStatus.message = error.localizedDescription
                resp.status = errStatus
            }
            responses.append(resp)
        }
        var response = Build_Bazel_Remote_Execution_V2_BatchUpdateBlobsResponse()
        response.responses = responses
        return response
    }

    func batchReadBlobs(
        request: Build_Bazel_Remote_Execution_V2_BatchReadBlobsRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_BatchReadBlobsResponse {
        var responses: [Build_Bazel_Remote_Execution_V2_BatchReadBlobsResponse.Response] = []
        for digest in request.digests {
            var resp = Build_Bazel_Remote_Execution_V2_BatchReadBlobsResponse.Response()
            resp.digest = digest
            do {
                resp.data = try await cas.fetch(digest)
                resp.status = .success
            } catch CASError.blobNotFound {
                var errStatus = Google_Rpc_Status()
                errStatus.code = 5 // NOT_FOUND
                errStatus.message = "Blob not found: \(digest.hash)"
                resp.status = errStatus
            } catch {
                var errStatus = Google_Rpc_Status()
                errStatus.code = 13 // INTERNAL
                errStatus.message = error.localizedDescription
                resp.status = errStatus
            }
            responses.append(resp)
        }
        var response = Build_Bazel_Remote_Execution_V2_BatchReadBlobsResponse()
        response.responses = responses
        return response
    }

    func getTree(
        request _: Build_Bazel_Remote_Execution_V2_GetTreeRequest,
        response _: GRPCCore.RPCWriter<Build_Bazel_Remote_Execution_V2_GetTreeResponse>,
        context _: GRPCCore.ServerContext
    ) async throws {
        // Not called by Buck2; return empty stream.
    }

    func splitBlob(
        request _: Build_Bazel_Remote_Execution_V2_SplitBlobRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_SplitBlobResponse {
        throw RPCError(code: .unimplemented, message: "SplitBlob not supported")
    }

    func spliceBlob(
        request _: Build_Bazel_Remote_Execution_V2_SpliceBlobRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_SpliceBlobResponse {
        throw RPCError(code: .unimplemented, message: "SpliceBlob not supported")
    }
}

// MARK: - Google_Rpc_Status convenience

private extension Google_Rpc_Status {
    static var success: Google_Rpc_Status {
        var status = Google_Rpc_Status()
        status.code = 0 // OK
        return status
    }
}
