import Foundation
@testable import reapi_shim
import SwiftProtobuf
import Testing

struct InputStagerTests {
    func makeTempCAS() throws -> ContentAddressableStorage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stager-test-\(UUID().uuidString)")
        return try ContentAddressableStorage(rootURL: url)
    }

    /// Builds a two-file, one-subdir Directory tree in CAS and returns the root digest.
    func buildSimpleTree(
        cas: ContentAddressableStorage
    ) async throws -> Build_Bazel_Remote_Execution_V2_Digest {
        // File: "hello.txt" containing "hello world"
        let helloData = Data("hello world\n".utf8)
        let helloDigest = try await cas.store(helloData)

        // Executable file: "run.sh" containing "#!/bin/sh\necho hi"
        let scriptData = Data("#!/bin/sh\necho hi\n".utf8)
        let scriptDigest = try await cas.store(scriptData)

        // Subdirectory "sub/" with one file "nested.txt"
        let nestedData = Data("nested\n".utf8)
        let nestedDigest = try await cas.store(nestedData)

        var nestedFile = Build_Bazel_Remote_Execution_V2_FileNode()
        nestedFile.name = "nested.txt"
        nestedFile.digest = nestedDigest
        nestedFile.isExecutable = false

        var subDir = Build_Bazel_Remote_Execution_V2_Directory()
        subDir.files = [nestedFile]
        let subDirData = try subDir.serializedData()
        let subDirDigest = try await cas.store(subDirData)

        // Root directory
        var helloNode = Build_Bazel_Remote_Execution_V2_FileNode()
        helloNode.name = "hello.txt"
        helloNode.digest = helloDigest
        helloNode.isExecutable = false

        var scriptNode = Build_Bazel_Remote_Execution_V2_FileNode()
        scriptNode.name = "run.sh"
        scriptNode.digest = scriptDigest
        scriptNode.isExecutable = true

        var subDirNode = Build_Bazel_Remote_Execution_V2_DirectoryNode()
        subDirNode.name = "sub"
        subDirNode.digest = subDirDigest

        var rootDir = Build_Bazel_Remote_Execution_V2_Directory()
        rootDir.files = [helloNode, scriptNode]
        rootDir.directories = [subDirNode]
        let rootData = try rootDir.serializedData()
        return try await cas.store(rootData)
    }

    @Test
    func `staged directory has correct files`() async throws {
        let cas = try makeTempCAS()
        let rootDigest = try await buildSimpleTree(cas: cas)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let stager = InputStager(cas: cas)
        try await stager.stage(rootDigest: rootDigest, into: workDir)

        let helloPath = workDir.appendingPathComponent("hello.txt").path
        let scriptPath = workDir.appendingPathComponent("run.sh").path
        let nestedPath = workDir.appendingPathComponent("sub/nested.txt").path

        #expect(FileManager.default.fileExists(atPath: helloPath))
        #expect(FileManager.default.fileExists(atPath: scriptPath))
        #expect(FileManager.default.fileExists(atPath: nestedPath))

        let content = try String(contentsOfFile: helloPath, encoding: .utf8)
        #expect(content == "hello world\n")
    }

    @Test
    func `executable bit is set on executable files`() async throws {
        let cas = try makeTempCAS()
        let rootDigest = try await buildSimpleTree(cas: cas)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let stager = InputStager(cas: cas)
        try await stager.stage(rootDigest: rootDigest, into: workDir)

        let scriptPath = workDir.appendingPathComponent("run.sh").path
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        #expect((perms & 0o100) != 0, "run.sh should be executable")

        let helloPath = workDir.appendingPathComponent("hello.txt").path
        let helloAttrs = try FileManager.default.attributesOfItem(atPath: helloPath)
        let helloPerms = helloAttrs[.posixPermissions] as? Int ?? 0
        #expect((helloPerms & 0o100) == 0, "hello.txt should not be executable")
    }
}
