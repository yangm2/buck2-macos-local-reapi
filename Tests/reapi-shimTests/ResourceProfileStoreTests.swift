@testable import reapi_shim
import Testing

struct ResourceProfileStoreTests {
    @Test
    func `profile returns nil for an action that has never been recorded`() async {
        let store = ResourceProfileStore()
        #expect(await store.profile(for: "unknown") == nil)
    }

    @Test
    func `profile returns 25% headroom over observed peak`() async {
        let store = ResourceProfileStore()
        await store.record(hash: "abc", memoryMB: 800, wallTimeSec: 1.0)
        let profile = await store.profile(for: "abc")
        // 800 * 1.25 = 1000, max(1000, 512) = 1000
        #expect(profile?.memoryMB == 1000)
    }

    @Test
    func `profile clamps to 512 MB minimum when headroom is below floor`() async {
        let store = ResourceProfileStore()
        await store.record(hash: "abc", memoryMB: 100, wallTimeSec: 0.5)
        let profile = await store.profile(for: "abc")
        // 100 * 1.25 = 125, max(125, 512) = 512
        #expect(profile?.memoryMB == 512)
    }

    @Test
    func `record overwrites the previous observation for the same hash`() async {
        let store = ResourceProfileStore()
        await store.record(hash: "abc", memoryMB: 100, wallTimeSec: 1.0)
        await store.record(hash: "abc", memoryMB: 2000, wallTimeSec: 2.0)
        let profile = await store.profile(for: "abc")
        // 2000 * 1.25 = 2500
        #expect(profile?.memoryMB == 2500)
    }

    @Test
    func `different hashes are stored independently`() async {
        let store = ResourceProfileStore()
        await store.record(hash: "aaa", memoryMB: 800, wallTimeSec: 1.0)
        await store.record(hash: "bbb", memoryMB: 2000, wallTimeSec: 2.0)
        #expect(await store.profile(for: "aaa")?.memoryMB == 1000)
        #expect(await store.profile(for: "bbb")?.memoryMB == 2500)
        #expect(await store.profile(for: "ccc") == nil)
    }
}
