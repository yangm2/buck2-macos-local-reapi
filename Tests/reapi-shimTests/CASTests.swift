import Foundation
@testable import reapi_shim
import Testing

struct CASTests {
    func makeTempCAS() throws -> ContentAddressableStorage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cas-test-\(UUID().uuidString)")
        return try ContentAddressableStorage(rootURL: url)
    }

    @Test("Round-trip: store then fetch returns original data")
    func roundTrip() async throws {
        let cas = try makeTempCAS()
        let data = Data("hello from CAS".utf8)
        let digest = try await cas.store(data)
        let fetched = try await cas.fetch(digest)
        #expect(fetched == data)
    }

    @Test("findMissing returns empty for stored blobs")
    func findMissingHit() async throws {
        let cas = try makeTempCAS()
        let data = Data("present blob".utf8)
        let digest = try await cas.store(data)
        let missing = await cas.findMissing([digest])
        #expect(missing.isEmpty)
    }

    @Test("findMissing returns digest for absent blobs")
    func findMissingMiss() async throws {
        let cas = try makeTempCAS()
        var phantom = Build_Bazel_Remote_Execution_V2_Digest()
        phantom.hash = String(repeating: "a", count: 64)
        phantom.sizeBytes = 42 // non-zero so it is not the empty-blob special case
        let missing = await cas.findMissing([phantom])
        #expect(missing.count == 1)
        #expect(missing[0].hash == phantom.hash)
    }

    @Test("findMissing never reports the empty blob as missing (REAPI invariant)")
    func findMissingEmptyBlob() async throws {
        let cas = try makeTempCAS()
        var emptyDigest = Build_Bazel_Remote_Execution_V2_Digest()
        emptyDigest.hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        emptyDigest.sizeBytes = 0
        let missing = await cas.findMissing([emptyDigest])
        #expect(missing.isEmpty, "empty blob must always be reported as present")
    }

    @Test("Fetch returns empty Data for the empty blob without disk access")
    func fetchEmptyBlob() async throws {
        let cas = try makeTempCAS()
        var emptyDigest = Build_Bazel_Remote_Execution_V2_Digest()
        emptyDigest.hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        emptyDigest.sizeBytes = 0
        let data = try await cas.fetch(emptyDigest)
        #expect(data.isEmpty)
    }

    @Test("Path sharding: blob lands in two-char prefix subdirectory")
    func pathSharding() async throws {
        let cas = try makeTempCAS()
        let data = Data("shard test".utf8)
        let digest = try await cas.store(data)
        let url = await cas.blobURL(for: digest)
        let prefix = String(digest.hash.prefix(2))
        #expect(url.path.contains("/\(prefix)/\(digest.hash)"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Store is idempotent: storing same blob twice is safe")
    func storeIdempotent() async throws {
        let cas = try makeTempCAS()
        let data = Data("idempotent".utf8)
        let digest1 = try await cas.store(data)
        let digest2 = try await cas.store(data)
        #expect(digest1.hash == digest2.hash)
        let fetched = try await cas.fetch(digest1)
        #expect(fetched == data)
    }

    @Test("Fetch throws for absent blob")
    func fetchMissingThrows() async throws {
        let cas = try makeTempCAS()
        var phantom = Build_Bazel_Remote_Execution_V2_Digest()
        phantom.hash = String(repeating: "b", count: 64)
        phantom.sizeBytes = 42 // non-zero so it is not the empty-blob special case
        await #expect(throws: CASError.self) {
            _ = try await cas.fetch(phantom)
        }
    }
}
