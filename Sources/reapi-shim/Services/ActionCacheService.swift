import GRPCCore
import GRPCProtobuf

/// REAPI `ActionCache` service backed by the in-memory ``ActionCache``.
///
/// Supports both `GetActionResult` (cache lookup) and `UpdateActionResult`
/// (explicit cache population). Buck2 calls `GetActionResult` on every action
/// before executing and `UpdateActionResult` when it wants to prime the cache.
struct ActionCacheService: Build_Bazel_Remote_Execution_V2_ActionCache.SimpleServiceProtocol {
    let cache: ActionCache

    func getActionResult(
        request: Build_Bazel_Remote_Execution_V2_GetActionResultRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        guard let result = await cache.get(actionDigest: request.actionDigest) else {
            throw RPCError(
                code: .notFound,
                message: "Action result not found: \(request.actionDigest.hash)"
            )
        }
        return result
    }

    func updateActionResult(
        request: Build_Bazel_Remote_Execution_V2_UpdateActionResultRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        await cache.put(actionDigest: request.actionDigest, result: request.actionResult)
        return request.actionResult
    }
}
