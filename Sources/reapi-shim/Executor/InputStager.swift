import Foundation
import SwiftProtobuf

/// Materializes a CAS Directory proto tree onto the local filesystem.
///
/// The staged directory is bind-mounted read-write into the container, so
/// output files written by the action appear on the host after execution.
struct InputStager {
    let cas: ContentAddressableStorage

    /// Recursively materialise `rootDigest` into `workDir`, returning `workDir`.
    func stage(
        rootDigest: Build_Bazel_Remote_Execution_V2_Digest,
        into workDir: URL
    ) async throws {
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
        try await stageDirectory(digest: rootDigest, at: workDir)
    }

    // MARK: - Private recursion

    private func stageDirectory(
        digest: Build_Bazel_Remote_Execution_V2_Digest,
        at dirURL: URL
    ) async throws {
        let data = try await cas.fetch(digest)
        let dir = try Build_Bazel_Remote_Execution_V2_Directory(serializedBytes: data)

        // Stage files
        for file in dir.files {
            let fileURL = dirURL.appendingPathComponent(file.name)
            let content = try await cas.fetch(file.digest)
            try content.write(to: fileURL)
            if file.isExecutable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: fileURL.path
                )
            }
        }

        // Stage symlinks
        for link in dir.symlinks {
            let linkURL = dirURL.appendingPathComponent(link.name)
            try FileManager.default.createSymbolicLink(
                atPath: linkURL.path,
                withDestinationPath: link.target
            )
        }

        // Recurse into subdirectories
        for subdir in dir.directories {
            let subdirURL = dirURL.appendingPathComponent(subdir.name)
            try FileManager.default.createDirectory(
                at: subdirURL,
                withIntermediateDirectories: true
            )
            try await stageDirectory(digest: subdir.digest, at: subdirURL)
        }
    }
}
