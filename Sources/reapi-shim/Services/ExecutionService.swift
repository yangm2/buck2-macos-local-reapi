import Foundation
import GRPCCore
import GRPCProtobuf
import SwiftProtobuf

/// REAPI `Execution` service that dispatches actions to an ``ActionExecutor``.
///
/// `Execute` streams a pending `Operation` immediately, runs the action inside
/// an ephemeral Apple Container VM, then streams the completed (or failed)
/// `Operation`. `WaitExecution` resumes a previously issued operation via the
/// shared ``OperationStore``.
struct ExecutionService: Build_Bazel_Remote_Execution_V2_Execution.SimpleServiceProtocol {
    let executor: any ActionExecutor
    let operationStore: OperationStore

    func execute(
        request: Build_Bazel_Remote_Execution_V2_ExecuteRequest,
        response: GRPCCore.RPCWriter<Google_Longrunning_Operation>,
        context _: GRPCCore.ServerContext
    ) async throws {
        let opName = "operations/\(request.actionDigest.hash)"
        let hash = request.actionDigest.hash
        let size = request.actionDigest.sizeBytes
        log("[Execute] action=\(hash):\(size) skipCache=\(request.skipCacheLookup)")

        // Immediately acknowledge: stream a pending operation
        try await response.write(pendingOperation(name: opName))
        await operationStore.set(name: opName, state: .running)

        do {
            let result = try await executor.execute(
                actionDigest: request.actionDigest,
                skipCacheLookup: request.skipCacheLookup
            )
            log("[Execute] done exit=\(result.exitCode)")
            await operationStore.set(name: opName, state: .done(result))
            try await response.write(completedOperation(name: opName, result: result))
        } catch {
            log("[Execute] error: \(error)")
            await operationStore.set(name: opName, state: .failed(error))
            try await response.write(failedOperation(name: opName, error: error))
        }
    }

    func waitExecution(
        request: Build_Bazel_Remote_Execution_V2_WaitExecutionRequest,
        response: GRPCCore.RPCWriter<Google_Longrunning_Operation>,
        context _: GRPCCore.ServerContext
    ) async throws {
        let result = try await operationStore.waitForCompletion(name: request.name)
        try await response.write(completedOperation(name: request.name, result: result))
    }

    // MARK: - Operation builders

    private func pendingOperation(name: String) -> Google_Longrunning_Operation {
        var operation = Google_Longrunning_Operation()
        operation.name = name
        operation.done = false
        return operation
    }

    private func completedOperation(
        name: String,
        result: Build_Bazel_Remote_Execution_V2_ActionResult
    ) throws -> Google_Longrunning_Operation {
        var executeResponse = Build_Bazel_Remote_Execution_V2_ExecuteResponse()
        executeResponse.result = result

        var operation = Google_Longrunning_Operation()
        operation.name = name
        operation.done = true
        operation.response = try Google_Protobuf_Any(message: executeResponse)
        return operation
    }

    private func failedOperation(name: String, error: Error) -> Google_Longrunning_Operation {
        var status = Google_Rpc_Status()
        status.code = 13 // INTERNAL
        status.message = error.localizedDescription

        var operation = Google_Longrunning_Operation()
        operation.name = name
        operation.done = true
        operation.error = status
        return operation
    }
}

// MARK: - OperationStore

/// In-memory store for in-flight and completed REAPI `Operation` state.
///
/// Callers waiting on a not-yet-complete operation are suspended via a
/// `CheckedContinuation` and resumed automatically when the result arrives.
actor OperationStore {
    enum State {
        case running
        case done(Build_Bazel_Remote_Execution_V2_ActionResult)
        case failed(Error)
    }

    private var states: [String: State] = [:]
    private var waiters:
        [String: [CheckedContinuation<Build_Bazel_Remote_Execution_V2_ActionResult, Error>]] = [:]

    func set(name: String, state: State) {
        states[name] = state
        switch state {
        case let .done(result):
            waiters.removeValue(forKey: name)?.forEach { $0.resume(returning: result) }
        case let .failed(error):
            waiters.removeValue(forKey: name)?.forEach { $0.resume(throwing: error) }
        case .running:
            break
        }
    }

    func waitForCompletion(
        name: String
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        switch states[name] {
        case let .done(result): return result
        case let .failed(error): throw error
        default:
            return try await withCheckedThrowingContinuation { continuation in
                waiters[name, default: []].append(continuation)
            }
        }
    }
}
