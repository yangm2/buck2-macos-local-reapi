import Foundation

/// Classifies action failures and prepends context headers to stderr output.
///
/// Three categories (§8.6):
/// - `[HERMETIC]` — action exited non-zero; likely a real build error or undeclared dependency.
/// - `[INFRA]`    — container infrastructure failure (OOM, startup timeout, vsock error).
/// - `[FLAKY]`    — intermittent failure (signal kill, possible OOM).
enum ErrorClassifier {
    enum Category {
        case hermetic
        case infra
        case flaky
    }

    struct ClassifiedError {
        let category: Category
        let header: String
        let originalStderr: String
    }

    /// Analyses container exit conditions and returns classified stderr.
    static func classify(
        exitCode: Int32,
        signal: Int32?,
        stderr: String,
        memoryLimitMB: Int,
        containerError: String?
    ) -> ClassifiedError {
        // Infrastructure failure: container process itself was killed / couldn't start
        if let containerError {
            let header = """
            [INFRA] Container failed to complete action.
            Cause: \(containerError)
            Suggestion: Check host memory pressure or increase VM memory limit.
            """
            return ClassifiedError(category: .infra, header: header, originalStderr: stderr)
        }

        // Likely OOM kill: killed by signal 9 with memory near limit
        if let sig = signal, sig == 9 {
            let header = """
            [FLAKY] Action killed with SIGKILL — possible OOM inside container.
            VM memory limit: \(memoryLimitMB) MB
            Suggestion: Increase memory limit for this action category.
            """
            return ClassifiedError(category: .flaky, header: header, originalStderr: stderr)
        }

        // Non-zero exit from the actual command: real build error
        let header = """
        [HERMETIC] Action exited with code \(exitCode).
        If this succeeds with `buck2 build --local-only`, you may have an undeclared dependency.
        """
        return ClassifiedError(category: .hermetic, header: header, originalStderr: stderr)
    }

    /// Rewrites container-internal paths (`/workspace/...`) to bare relative paths.
    static func rewritePaths(_ text: String, workspaceMount: String = "/workspace") -> String {
        text.replacingOccurrences(of: workspaceMount + "/", with: "")
    }

    /// Builds the final stderr string: header + separator + original compiler output.
    static func format(_ classified: ClassifiedError) -> String {
        if classified.originalStderr.isEmpty {
            return classified.header
        }
        return classified.header + "\n---\n" + classified.originalStderr
    }
}
