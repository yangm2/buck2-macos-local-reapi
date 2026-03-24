@testable import reapi_shim
import Testing

struct ErrorClassifierTests {
    // MARK: - classify

    @Test("containerError produces INFRA category")
    func classifyInfra() {
        let result = ErrorClassifier.classify(
            exitCode: 1,
            signal: nil,
            stderr: "some output",
            memoryLimitMB: 512,
            containerError: "vsock timeout"
        )
        #expect(result.category == .infra)
        #expect(result.header.contains("[INFRA]"))
        #expect(result.header.contains("vsock timeout"))
        #expect(result.originalStderr == "some output")
    }

    @Test("SIGKILL produces FLAKY category with memory limit in header")
    func classifyFlaky() {
        let result = ErrorClassifier.classify(
            exitCode: -1,
            signal: 9,
            stderr: "",
            memoryLimitMB: 1024,
            containerError: nil
        )
        #expect(result.category == .flaky)
        #expect(result.header.contains("[FLAKY]"))
        #expect(result.header.contains("1024"))
    }

    @Test("Non-zero exit produces HERMETIC category with exit code in header")
    func classifyHermetic() {
        let result = ErrorClassifier.classify(
            exitCode: 2,
            signal: nil,
            stderr: "build failed",
            memoryLimitMB: 512,
            containerError: nil
        )
        #expect(result.category == .hermetic)
        #expect(result.header.contains("[HERMETIC]"))
        #expect(result.header.contains("2"))
    }

    @Test("containerError takes precedence over SIGKILL")
    func classifyInfraTakesPrecedenceOverSignal() {
        let result = ErrorClassifier.classify(
            exitCode: -1,
            signal: 9,
            stderr: "",
            memoryLimitMB: 512,
            containerError: "OOM killer"
        )
        #expect(result.category == .infra)
    }

    @Test("Non-9 signal falls through to HERMETIC")
    func classifyNonKillSignal() {
        let result = ErrorClassifier.classify(
            exitCode: 1,
            signal: 11, // SIGSEGV
            stderr: "",
            memoryLimitMB: 512,
            containerError: nil
        )
        #expect(result.category == .hermetic)
    }

    // MARK: - rewritePaths

    @Test("rewritePaths strips /workspace/ prefix")
    func rewritePathsStripsPrefix() {
        let input = "/workspace/src/foo.cpp:10: error: undeclared identifier"
        let output = ErrorClassifier.rewritePaths(input)
        #expect(output == "src/foo.cpp:10: error: undeclared identifier")
    }

    @Test("rewritePaths replaces all occurrences")
    func rewritePathsMultiple() {
        let input = "/workspace/a.cpp and /workspace/b.cpp"
        let output = ErrorClassifier.rewritePaths(input)
        #expect(output == "a.cpp and b.cpp")
    }

    @Test("rewritePaths is a no-op when no workspace prefix present")
    func rewritePathsNoOp() {
        let input = "no paths here"
        #expect(ErrorClassifier.rewritePaths(input) == input)
    }

    // MARK: - format

    @Test("format returns header only when stderr is empty")
    func formatEmptyStderr() {
        let classified = ErrorClassifier.ClassifiedError(
            category: .hermetic,
            header: "the header",
            originalStderr: ""
        )
        #expect(ErrorClassifier.format(classified) == "the header")
    }

    @Test("format appends separator and stderr when non-empty")
    func formatWithStderr() {
        let classified = ErrorClassifier.ClassifiedError(
            category: .hermetic,
            header: "the header",
            originalStderr: "compiler output"
        )
        let result = ErrorClassifier.format(classified)
        #expect(result.hasPrefix("the header"))
        #expect(result.contains("\n---\n"))
        #expect(result.hasSuffix("compiler output"))
    }
}
