import Foundation
@testable import reapi_shim
import Testing

struct OutputCollectorTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("output-collector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCAS() throws -> ContentAddressableStorage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("output-collector-cas-\(UUID().uuidString)")
        return try ContentAddressableStorage(rootURL: url)
    }

    @Test("Non-existent output path is silently skipped")
    func collectMissingPath() async throws {
        let collector = try OutputCollector(cas: makeCAS())
        let outputs = try await collector.collect(
            outputPaths: ["nonexistent.txt"],
            workDir: makeTempDir()
        )
        #expect(outputs.isEmpty)
    }

    @Test("File is stored in CAS and returned as OutputFile")
    func collectFile() async throws {
        let cas = try makeCAS()
        let workDir = try makeTempDir()
        let content = Data("hello output".utf8)
        try content.write(to: workDir.appendingPathComponent("out.txt"))

        let collector = OutputCollector(cas: cas)
        let outputs = try await collector.collect(outputPaths: ["out.txt"], workDir: workDir)

        #expect(outputs.count == 1)
        #expect(outputs[0].path == "out.txt")
        let fetched = try await cas.fetch(outputs[0].digest)
        #expect(fetched == content)
    }

    @Test("Executable bit is reflected in isExecutable")
    func collectExecutableBit() async throws {
        let workDir = try makeTempDir()
        let fileURL = workDir.appendingPathComponent("run.sh")
        try Data("#!/bin/sh".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)

        let collector = try OutputCollector(cas: makeCAS())
        let outputs = try await collector.collect(outputPaths: ["run.sh"], workDir: workDir)

        #expect(outputs[0].isExecutable)
    }

    @Test("Non-executable file has isExecutable false")
    func collectNonExecutable() async throws {
        let workDir = try makeTempDir()
        let fileURL = workDir.appendingPathComponent("data.bin")
        try Data("data".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let collector = try OutputCollector(cas: makeCAS())
        let outputs = try await collector.collect(outputPaths: ["data.bin"], workDir: workDir)

        #expect(!outputs[0].isExecutable)
    }

    @Test("Directory output is collected recursively")
    func collectDirectory() async throws {
        let workDir = try makeTempDir()
        let subdir = workDir.appendingPathComponent("outdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data("file1".utf8).write(to: subdir.appendingPathComponent("a.txt"))
        try Data("file2".utf8).write(to: subdir.appendingPathComponent("b.txt"))

        let collector = try OutputCollector(cas: makeCAS())
        let outputs = try await collector.collect(outputPaths: ["outdir"], workDir: workDir)

        #expect(outputs.count == 2)
        let paths = Set(outputs.map(\.path))
        #expect(paths.contains("outdir/a.txt"))
        #expect(paths.contains("outdir/b.txt"))
    }

    @Test("Multiple output paths are all collected")
    func collectMultiplePaths() async throws {
        let cas = try makeCAS()
        let workDir = try makeTempDir()
        try Data("a".utf8).write(to: workDir.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: workDir.appendingPathComponent("b.txt"))

        let collector = OutputCollector(cas: cas)
        let outputs = try await collector.collect(
            outputPaths: ["a.txt", "b.txt"],
            workDir: workDir
        )

        #expect(outputs.count == 2)
    }
}
