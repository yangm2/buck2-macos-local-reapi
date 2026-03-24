import OSLog
import SwiftProtobuf

private let logger = Logger(subsystem: "dev.reapi-shim", category: "Router")

/// Routes REAPI actions to the appropriate executor based on platform properties.
///
/// Actions that declare `requires-gpu=true`, `OSFamily=macos`, or request
/// more than 16 GiB RAM are forwarded to the configured remote executor.
/// All other actions run in a local Apple Container VM. When no remote
/// executor is configured every action runs locally regardless of platform.
struct PlatformRouter: ActionExecutor {
    let cas: ContentAddressableStorage
    let local: any ActionExecutor
    let remote: (any ActionExecutor)?

    func execute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        let selected = try await selectExecutor(for: actionDigest)
        return try await selected.execute(
            actionDigest: actionDigest,
            skipCacheLookup: skipCacheLookup
        )
    }

    // MARK: - Routing

    private func selectExecutor(
        for actionDigest: Build_Bazel_Remote_Execution_V2_Digest
    ) async throws -> any ActionExecutor {
        guard let remote else { return local }
        let actionData = try await cas.fetch(actionDigest)
        let action = try Build_Bazel_Remote_Execution_V2_Action(serializedBytes: actionData)
        if shouldRouteRemote(action.platform) {
            let shortHash = actionDigest.hash.prefix(16)
            logger.debug("routing \(shortHash, privacy: .public) → remote")
            return remote
        }
        return local
    }

    /// Returns `true` when the action must run on the remote executor.
    ///
    /// Routing triggers (from DEVELOPMENT.md §3.2):
    /// - `requires-gpu=true` — GPU unavailable in local Apple Container VMs
    /// - `OSFamily=macos` — macOS containers require Tart / remote worker
    /// - `min-ram` > 16 384 MB — exceeds practical local VM ceiling
    private func shouldRouteRemote(
        _ platform: Build_Bazel_Remote_Execution_V2_Platform
    ) -> Bool {
        for prop in platform.properties {
            switch (prop.name, prop.value) {
            case ("requires-gpu", "true"), ("OSFamily", "macos"):
                return true
            default:
                break
            }
        }
        let props = Dictionary(
            uniqueKeysWithValues: platform.properties.map { ($0.name, $0.value) }
        )
        if let minRam = props["min-ram"].flatMap(Int.init), minRam > 16 * 1024 {
            return true
        }
        return false
    }
}
