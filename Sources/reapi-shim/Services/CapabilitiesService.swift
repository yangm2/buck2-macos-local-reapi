import GRPCCore
import GRPCProtobuf

/// REAPI `Capabilities` service advertising what this shim supports.
///
/// Declares SHA-256 digests, a 4 MiB batch limit, execution enabled, and
/// REAPI version 2.x. Buck2 calls `GetCapabilities` at session start to
/// negotiate protocol features.
struct CapabilitiesService: Build_Bazel_Remote_Execution_V2_Capabilities.SimpleServiceProtocol {
    func getCapabilities(
        request _: Build_Bazel_Remote_Execution_V2_GetCapabilitiesRequest,
        context _: GRPCCore.ServerContext
    ) async throws -> Build_Bazel_Remote_Execution_V2_ServerCapabilities {
        var caps = Build_Bazel_Remote_Execution_V2_ServerCapabilities()

        var casCaps = Build_Bazel_Remote_Execution_V2_CacheCapabilities()
        casCaps.digestFunctions = [.sha256]
        casCaps.maxBatchTotalSizeBytes = 4 * 1024 * 1024
        casCaps.symlinkAbsolutePathStrategy = .disallowed
        var actionCachePerm = Build_Bazel_Remote_Execution_V2_ActionCacheUpdateCapabilities()
        actionCachePerm.updateEnabled = true
        casCaps.actionCacheUpdateCapabilities = actionCachePerm
        caps.cacheCapabilities = casCaps

        var execCaps = Build_Bazel_Remote_Execution_V2_ExecutionCapabilities()
        execCaps.digestFunction = .sha256
        execCaps.execEnabled = true
        caps.executionCapabilities = execCaps

        var low = Build_Bazel_Semver_SemVer()
        low.major = 2
        caps.lowApiVersion = low
        var high = Build_Bazel_Semver_SemVer()
        high.major = 2
        caps.highApiVersion = high

        return caps
    }
}
