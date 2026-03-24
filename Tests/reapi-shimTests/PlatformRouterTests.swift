import Foundation
@testable import reapi_shim
import SwiftProtobuf
import Testing

// MARK: - Test infrastructure

private func makeTempCAS() throws -> ContentAddressableStorage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("router-test-cas-\(UUID().uuidString)")
    return try ContentAddressableStorage(rootURL: url)
}

/// A minimal ``ActionExecutor`` that records how many times it was called.
private actor MockExecutor: ActionExecutor {
    private(set) var callCount = 0

    func execute(
        actionDigest _: Build_Bazel_Remote_Execution_V2_Digest,
        skipCacheLookup _: Bool
    ) async throws -> Build_Bazel_Remote_Execution_V2_ActionResult {
        callCount += 1
        return Build_Bazel_Remote_Execution_V2_ActionResult()
    }
}

/// Stores a minimal Action with `platform` in `cas` and returns its digest.
private func storeAction(
    platform: Build_Bazel_Remote_Execution_V2_Platform,
    in cas: ContentAddressableStorage
) async throws -> Build_Bazel_Remote_Execution_V2_Digest {
    var action = Build_Bazel_Remote_Execution_V2_Action()
    action.platform = platform
    let data = try action.serializedData()
    return try await cas.store(data)
}

/// Builds a Platform with a single property.
private func platform(
    _ name: String,
    _ value: String
) -> Build_Bazel_Remote_Execution_V2_Platform {
    var prop = Build_Bazel_Remote_Execution_V2_Platform.Property()
    prop.name = name
    prop.value = value
    var plat = Build_Bazel_Remote_Execution_V2_Platform()
    plat.properties = [prop]
    return plat
}

// MARK: - Routing tests

struct PlatformRouterTests {
    @Test
    func `empty platform routes to local executor`() async throws {
        let cas = try makeTempCAS()
        let mockLocal = MockExecutor()
        let mockRemote = MockExecutor()
        let digest = try await storeAction(
            platform: Build_Bazel_Remote_Execution_V2_Platform(),
            in: cas
        )
        let router = PlatformRouter(cas: cas, local: mockLocal, remote: mockRemote)
        _ = try await router.execute(actionDigest: digest, skipCacheLookup: true)
        #expect(await mockLocal.callCount == 1)
        #expect(await mockRemote.callCount == 0)
    }

    @Test
    func `requires-gpu=true routes to remote executor`() async throws {
        let cas = try makeTempCAS()
        let mockLocal = MockExecutor()
        let mockRemote = MockExecutor()
        let digest = try await storeAction(platform: platform("requires-gpu", "true"), in: cas)
        let router = PlatformRouter(cas: cas, local: mockLocal, remote: mockRemote)
        _ = try await router.execute(actionDigest: digest, skipCacheLookup: true)
        #expect(await mockLocal.callCount == 0)
        #expect(await mockRemote.callCount == 1)
    }

    @Test
    func `OSFamily=macos routes to remote executor`() async throws {
        let cas = try makeTempCAS()
        let mockLocal = MockExecutor()
        let mockRemote = MockExecutor()
        let digest = try await storeAction(platform: platform("OSFamily", "macos"), in: cas)
        let router = PlatformRouter(cas: cas, local: mockLocal, remote: mockRemote)
        _ = try await router.execute(actionDigest: digest, skipCacheLookup: true)
        #expect(await mockLocal.callCount == 0)
        #expect(await mockRemote.callCount == 1)
    }

    @Test
    func `OSFamily=linux routes to local executor`() async throws {
        let cas = try makeTempCAS()
        let mockLocal = MockExecutor()
        let mockRemote = MockExecutor()
        let digest = try await storeAction(platform: platform("OSFamily", "linux"), in: cas)
        let router = PlatformRouter(cas: cas, local: mockLocal, remote: mockRemote)
        _ = try await router.execute(actionDigest: digest, skipCacheLookup: true)
        #expect(await mockLocal.callCount == 1)
        #expect(await mockRemote.callCount == 0)
    }

    @Test
    func `min-ram above 16 GiB routes to remote executor`() async throws {
        let cas = try makeTempCAS()
        let mockLocal = MockExecutor()
        let mockRemote = MockExecutor()
        let digest = try await storeAction(platform: platform("min-ram", "20480"), in: cas)
        let router = PlatformRouter(cas: cas, local: mockLocal, remote: mockRemote)
        _ = try await router.execute(actionDigest: digest, skipCacheLookup: true)
        #expect(await mockLocal.callCount == 0)
        #expect(await mockRemote.callCount == 1)
    }

    @Test
    func `min-ram at 16 GiB routes to local executor`() async throws {
        let cas = try makeTempCAS()
        let mockLocal = MockExecutor()
        let mockRemote = MockExecutor()
        let digest = try await storeAction(platform: platform("min-ram", "16384"), in: cas)
        let router = PlatformRouter(cas: cas, local: mockLocal, remote: mockRemote)
        _ = try await router.execute(actionDigest: digest, skipCacheLookup: true)
        #expect(await mockLocal.callCount == 1)
        #expect(await mockRemote.callCount == 0)
    }

    @Test
    func `no remote configured: GPU action still routes to local`() async throws {
        let cas = try makeTempCAS()
        let mockLocal = MockExecutor()
        let digest = try await storeAction(platform: platform("requires-gpu", "true"), in: cas)
        let router = PlatformRouter(cas: cas, local: mockLocal, remote: nil)
        _ = try await router.execute(actionDigest: digest, skipCacheLookup: true)
        #expect(await mockLocal.callCount == 1)
    }
}
