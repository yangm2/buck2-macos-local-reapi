@testable import reapi_shim
import Testing

struct OperationStoreTests {
    @Test
    func `waitForCompletion returns result already set before waiting`() async throws {
        let store = OperationStore()
        var result = Build_Bazel_Remote_Execution_V2_ActionResult()
        result.exitCode = 0
        await store.set(name: "op1", state: .done(result))
        let fetched = try await store.waitForCompletion(name: "op1")
        #expect(fetched.exitCode == 0)
    }

    @Test
    func `waitForCompletion throws for failure already set before waiting`() async throws {
        struct FakeError: Error {}
        let store = OperationStore()
        await store.set(name: "op1", state: .failed(FakeError()))
        await #expect(throws: FakeError.self) {
            _ = try await store.waitForCompletion(name: "op1")
        }
    }

    @Test
    func `waitForCompletion suspends and is resumed when result is set`() async throws {
        let store = OperationStore()
        var result = Build_Bazel_Remote_Execution_V2_ActionResult()
        result.exitCode = 42
        async let fetched = store.waitForCompletion(name: "op1")
        await store.set(name: "op1", state: .done(result))
        #expect(try await fetched.exitCode == 42)
    }

    @Test
    func `waitForCompletion suspends and throws when failure is set`() async throws {
        struct FakeError: Error {}
        let store = OperationStore()
        let waiterTask = Task<Build_Bazel_Remote_Execution_V2_ActionResult, Error> {
            try await store.waitForCompletion(name: "op1")
        }
        await store.set(name: "op1", state: .failed(FakeError()))
        await #expect(throws: FakeError.self) {
            _ = try await waiterTask.value
        }
    }

    @Test
    func `multiple concurrent waiters are all resumed with the same result`() async throws {
        let store = OperationStore()
        var result = Build_Bazel_Remote_Execution_V2_ActionResult()
        result.exitCode = 7
        async let waiter1 = store.waitForCompletion(name: "op1")
        async let waiter2 = store.waitForCompletion(name: "op1")
        await store.set(name: "op1", state: .done(result))
        #expect(try await waiter1.exitCode == 7)
        #expect(try await waiter2.exitCode == 7)
    }

    @Test
    func `different operation names are tracked independently`() async throws {
        let store = OperationStore()
        var result1 = Build_Bazel_Remote_Execution_V2_ActionResult()
        result1.exitCode = 1
        var result2 = Build_Bazel_Remote_Execution_V2_ActionResult()
        result2.exitCode = 2
        await store.set(name: "op1", state: .done(result1))
        await store.set(name: "op2", state: .done(result2))
        #expect(try await store.waitForCompletion(name: "op1").exitCode == 1)
        #expect(try await store.waitForCompletion(name: "op2").exitCode == 2)
    }
}
