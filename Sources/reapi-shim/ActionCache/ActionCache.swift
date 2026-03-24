import Foundation
import OSLog
import SwiftProtobuf

private let logger = Logger(subsystem: "dev.reapi-shim", category: "ActionCache")

/// Filesystem-backed action cache mapping action digests to their computed results.
///
/// Entries are stored at `{rootURL}/{hash[0..<2]}/{hash}` as serialised
/// `ActionResult` protobufs using the same atomic write-then-rename pattern as
/// the CAS. Cache entries survive process restarts; a hit requires only that
/// the serialised bytes on disk parse successfully.
actor ActionCache {
    private let rootURL: URL
    private var hitCount = 0
    private var missCount = 0

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: - Cache operations

    func get(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest
    ) -> Build_Bazel_Remote_Execution_V2_ActionResult? {
        let url = entryURL(for: actionDigest.hash)
        guard let data = try? Data(contentsOf: url),
              let result = try? Build_Bazel_Remote_Execution_V2_ActionResult(serializedBytes: data)
        else {
            missCount += 1
            return nil
        }
        hitCount += 1
        return result
    }

    func put(
        actionDigest: Build_Bazel_Remote_Execution_V2_Digest,
        result: Build_Bazel_Remote_Execution_V2_ActionResult
    ) {
        let dest = entryURL(for: actionDigest.hash)
        do {
            let data = try result.serializedData()
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let tmp = dest.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            let hash = actionDigest.hash
            logger.warning("ActionCache put failed for \(hash, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Diagnostics

    var stats: (hits: Int, misses: Int) {
        (hitCount, missCount)
    }

    // MARK: - Private helpers

    private func entryURL(for hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return rootURL
            .appendingPathComponent(prefix)
            .appendingPathComponent(hash)
    }
}
