import Foundation

/// In-memory action cache mapping action digests to their previously computed results.
///
/// Cache entries persist for the lifetime of the process (one `buckd` session).
/// Thread-safety is provided by the actor model.
actor ActionCache {
    private var cache: [String: Build_Bazel_Remote_Execution_V2_ActionResult] = [:]
    private var hitCount = 0
    private var missCount = 0

    // MARK: - Cache operations

    func get(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest
    ) -> Build_Bazel_Remote_Execution_V2_ActionResult? {
        if let result = cache[actionDigest.hash] {
            hitCount += 1
            return result
        }
        missCount += 1
        return nil
    }

    func put(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        result: Build_Bazel_Remote_Execution_V2_ActionResult
    ) {
        cache[actionDigest.hash] = result
    }

    // MARK: - Diagnostics

    var stats: (hits: Int, misses: Int) {
        (hitCount, missCount)
    }

    var count: Int {
        cache.count
    }
}
