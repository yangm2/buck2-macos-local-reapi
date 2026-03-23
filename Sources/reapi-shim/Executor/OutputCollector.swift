import Foundation
import SwiftProtobuf

/// Reads declared output paths from the staged work directory and stores them in CAS.
struct OutputCollector {
    let cas: ContentAddressableStorage

    /// Collects `outputPaths` (relative to `workDir`) into CAS.
    /// Returns the list of `OutputFile` entries for the `ActionResult`.
    func collect(
        outputPaths: [String],
        workDir: URL
    ) async throws -> [Build_Bazel_Remote_Execution_V2_OutputFile] {
        var outputs: [Build_Bazel_Remote_Execution_V2_OutputFile] = []

        for path in outputPaths {
            let fileURL = workDir.appendingPathComponent(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
                // Buck2 may declare outputs that weren't produced (e.g. optional outputs)
                continue
            }

            if isDir.boolValue {
                // Collect directory tree recursively
                let dirOutputs = try await collectDirectory(at: fileURL, relativePath: path)
                outputs.append(contentsOf: dirOutputs)
            } else {
                let output = try await collectFile(at: fileURL, path: path)
                outputs.append(output)
            }
        }

        return outputs
    }

    // MARK: - Private helpers

    private func collectFile(
        at fileURL: URL,
        path: String
    ) async throws -> Build_Bazel_Remote_Execution_V2_OutputFile {
        let data = try Data(contentsOf: fileURL)
        let digest = try await cas.store(data)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let posixPerms = (attrs[.posixPermissions] as? Int) ?? 0o644
        let isExecutable = (posixPerms & 0o100) != 0

        var output = Build_Bazel_Remote_Execution_V2_OutputFile()
        output.path = path
        output.digest = digest
        output.isExecutable = isExecutable
        return output
    }

    private func collectDirectory(
        at dirURL: URL,
        relativePath: String
    ) async throws -> [Build_Bazel_Remote_Execution_V2_OutputFile] {
        var outputs: [Build_Bazel_Remote_Execution_V2_OutputFile] = []
        let contents = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        )
        for item in contents {
            let itemPath = relativePath + "/" + item.lastPathComponent
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue {
                let sub = try await collectDirectory(at: item, relativePath: itemPath)
                outputs.append(contentsOf: sub)
            } else {
                let output = try await collectFile(at: item, path: itemPath)
                outputs.append(output)
            }
        }
        return outputs
    }
}
