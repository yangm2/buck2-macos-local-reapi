import CryptoKit
import Foundation

/// Filesystem-backed content-addressable storage.
///
/// Blobs are stored at `{rootURL}/{hash[0..<2]}/{hash}` using atomic
/// write-then-rename to prevent partial reads. SHA-256 is computed via CryptoKit.
actor ContentAddressableStorage {
    let rootURL: URL

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: - Core operations

    /// Stores `data` and returns its digest. Idempotent: safe to call for
    /// content already present.
    func store(_ data: Data) throws -> Build_Bazel_Remote_Execution_V2_Digest {
        let digest = Self.digest(for: data)
        let dest = blobURL(for: digest)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            return digest
        }
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // Atomic rename; if another writer raced us, let it win.
        _ = try? FileManager.default.moveItem(at: tmp, to: dest)
        return digest
    }

    /// Returns blobs from `digests` that are not present locally.
    ///
    /// Per the REAPI spec the empty blob is implicitly always present and must
    /// never be reported as missing, regardless of what is on disk.
    func findMissing(
        _ digests: [Build_Bazel_Remote_Execution_V2_Digest]
    ) -> [Build_Bazel_Remote_Execution_V2_Digest] {
        digests.filter {
            $0.sizeBytes != 0 &&
                !FileManager.default.fileExists(atPath: blobURL(for: $0).path)
        }
    }

    /// Fetches the raw bytes for `digest`. Throws if not present.
    ///
    /// The empty blob is served directly without a filesystem round-trip.
    func fetch(_ digest: Build_Bazel_Remote_Execution_V2_Digest) throws -> Data {
        if digest.sizeBytes == 0 { return Data() }
        let url = blobURL(for: digest)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CASError.blobNotFound(digest.hash)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Helpers

    nonisolated func blobURL(for digest: Build_Bazel_Remote_Execution_V2_Digest) -> URL {
        let hash = digest.hash
        let prefix = String(hash.prefix(2))
        return rootURL
            .appendingPathComponent(prefix)
            .appendingPathComponent(hash)
    }

    static func digest(for data: Data) -> Build_Bazel_Remote_Execution_V2_Digest {
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        var digest = Build_Bazel_Remote_Execution_V2_Digest()
        digest.hash = hash
        digest.sizeBytes = Int64(data.count)
        return digest
    }
}

enum CASError: Error, CustomStringConvertible {
    case blobNotFound(String)

    var description: String {
        switch self {
        case let .blobNotFound(hash): "CAS blob not found: \(hash)"
        }
    }
}
