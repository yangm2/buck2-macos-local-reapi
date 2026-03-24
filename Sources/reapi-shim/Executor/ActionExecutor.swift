import SwiftProtobuf

/// Backend that can execute a REAPI action and return an ``ActionResult``.
///
/// Both ``ContainerExecutor`` (local Apple Container VM) and ``RemoteExecutor``
/// (upstream REAPI endpoint) conform to this protocol. ``PlatformRouter``
/// selects the appropriate backend at dispatch time based on the action's
/// platform properties.
protocol ActionExecutor: Sendable {
    func execute(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult
}
