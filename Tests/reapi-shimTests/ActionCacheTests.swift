import Foundation
@testable import reapi_shim
import Testing

struct ActionCacheTests {
    func makeDigest(_ hash: String) -> Build_Bazel_Remote_Execution_V2_Digest {
        var digest = Build_Bazel_Remote_Execution_V2_Digest()
        digest.hash = String(hash.prefix(64).padding(toLength: 64, withPad: "0", startingAt: 0))
        digest.sizeBytes = 42
        return digest
    }

    func makeResult(exitCode: Int32 = 0) -> Build_Bazel_Remote_Execution_V2_ActionResult {
        var result = Build_Bazel_Remote_Execution_V2_ActionResult()
        result.exitCode = exitCode
        return result
    }

    @Test("get on empty cache returns nil")
    func getEmpty() async {
        let cache = ActionCache()
        let result = await cache.get(actionDigest: makeDigest("aaa"))
        #expect(result == nil)
    }

    @Test("put then get returns stored result")
    func putGet() async {
        let cache = ActionCache()
        let digest = makeDigest("abc")
        let expected = makeResult(exitCode: 0)
        await cache.put(actionDigest: digest, result: expected)
        let actual = await cache.get(actionDigest: digest)
        #expect(actual?.exitCode == expected.exitCode)
    }

    @Test("Different digests are independent")
    func digestIndependence() async {
        let cache = ActionCache()
        let digest1 = makeDigest("111")
        let digest2 = makeDigest("222")
        await cache.put(actionDigest: digest1, result: makeResult(exitCode: 1))
        await cache.put(actionDigest: digest2, result: makeResult(exitCode: 2))
        let result1 = await cache.get(actionDigest: digest1)
        let result2 = await cache.get(actionDigest: digest2)
        #expect(result1?.exitCode == 1)
        #expect(result2?.exitCode == 2)
    }

    @Test("Stats track hits and misses")
    func stats() async {
        let cache = ActionCache()
        let digest = makeDigest("stats")
        // Two misses
        _ = await cache.get(actionDigest: digest)
        _ = await cache.get(actionDigest: digest)
        // One hit
        await cache.put(actionDigest: digest, result: makeResult())
        _ = await cache.get(actionDigest: digest)
        let stats = await cache.stats
        #expect(stats.misses == 2)
        #expect(stats.hits == 1)
    }
}
