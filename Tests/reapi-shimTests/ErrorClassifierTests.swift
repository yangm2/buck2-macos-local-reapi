@testable import reapi_shim
import Testing

struct ErrorClassifierTests {
    // MARK: - classify

    @Test
    func `containerError produces INFRA category`() {
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

    @Test
    func `SIGKILL produces FLAKY category with memory limit in header`() {
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

    @Test
    func `non-zero exit produces HERMETIC category with exit code in header`() {
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

    @Test
    func `containerError takes precedence over SIGKILL`() {
        let result = ErrorClassifier.classify(
            exitCode: -1,
            signal: 9,
            stderr: "",
            memoryLimitMB: 512,
            containerError: "OOM killer"
        )
        #expect(result.category == .infra)
    }

    @Test
    func `non-9 signal falls through to HERMETIC`() {
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

    @Test
    func `rewritePaths strips /workspace/ prefix`() {
        let input = "/workspace/src/foo.cpp:10: error: undeclared identifier"
        let output = ErrorClassifier.rewritePaths(input)
        #expect(output == "src/foo.cpp:10: error: undeclared identifier")
    }

    @Test
    func `rewritePaths replaces all occurrences`() {
        let input = "/workspace/a.cpp and /workspace/b.cpp"
        let output = ErrorClassifier.rewritePaths(input)
        #expect(output == "a.cpp and b.cpp")
    }

    @Test
    func `rewritePaths is a no-op when no workspace prefix present`() {
        let input = "no paths here"
        #expect(ErrorClassifier.rewritePaths(input) == input)
    }

    // MARK: - format

    @Test
    func `format returns header only when stderr is empty`() {
        let classified = ErrorClassifier.ClassifiedError(
            category: .hermetic,
            header: "the header",
            originalStderr: ""
        )
        #expect(ErrorClassifier.format(classified) == "the header")
    }

    @Test
    func `format appends separator and stderr when non-empty`() {
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
