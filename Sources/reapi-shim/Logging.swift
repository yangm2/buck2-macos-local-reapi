import Darwin

/// Writes a log line directly to stderr (unbuffered), bypassing Swift's
/// stdout buffer so messages appear immediately even in non-TTY contexts.
func log(_ message: String) {
    fputs("[shim] \(message)\n", stderr)
}
