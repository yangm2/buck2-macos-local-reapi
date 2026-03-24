import OSLog

/// Shared logger for call sites that have not yet migrated to a file-local Logger.
private let shimLogger = Logger(subsystem: "dev.reapi-shim", category: "Shim")

/// Writes a message to the unified logging system at info level.
///
/// Prefer declaring a file-local `Logger` with a specific category over calling
/// this function from new code.
func log(_ message: String) {
    shimLogger.info("\(message, privacy: .public)")
}
