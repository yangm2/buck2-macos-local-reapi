import Darwin
import Foundation
import SwiftProtobuf

/// Materializes a CAS Directory proto tree onto the local filesystem.
///
/// The staged directory is bind-mounted read-write into the container, so
/// output files written by the action appear on the host after execution.
///
/// Files are materialized using `clonefile(2)` when the CAS and staging
/// directory share an APFS volume, giving O(1) copy-on-write clones at
/// near-zero cost. A byte-copy fallback handles cross-device cases.
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

        // Stage files — attempt O(1) APFS clone; fall back to byte copy.
        for file in dir.files {
            let fileURL = dirURL.appendingPathComponent(file.name)
            try await stageFile(file, at: fileURL)
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

    /// Materializes a single file, preferring an APFS clone over a byte copy.
    ///
    /// `clonefile(2)` shares extents between the CAS blob and the staged file
    /// with copy-on-write semantics — no data is copied unless one side writes.
    /// It fails with `EXDEV` when src and dst live on different volumes, which
    /// triggers the byte-copy fallback.
    ///
    /// `EEXIST` is treated as a no-op: Buck2 genrule input trees routinely
    /// reference the same CAS blob at multiple paths (e.g. a source file
    /// appears under both its canonical path and the genrule `srcs/` directory).
    /// Because all blobs are content-addressed, an already-present file with
    /// the same name has identical content and can be safely skipped.
    private func stageFile(
        _ file: Build_Bazel_Remote_Execution_V2_FileNode,
        at fileURL: URL
    ) async throws {
        let src = cas.blobURL(for: file.digest).path
        let dst = fileURL.path
        let cloneResult = Darwin.clonefile(src, dst, 0)
        if cloneResult != 0 {
            if errno == EEXIST {
                // File already staged (same content-addressed blob) — skip.
                return
            }
            let content = try await cas.fetch(file.digest)
            try content.write(to: fileURL, options: .atomic)
        }
        if file.isExecutable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dst
            )
        }
    }
}
