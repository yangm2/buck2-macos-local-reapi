import ContainerResource
import Foundation

// MARK: - ContainerProcess

/// A running process inside a container.
///
/// This local protocol mirrors the subset of ``ClientProcess`` that
/// ``ContainerExecutor`` actually uses, so tests can supply a mock without
/// importing the SDK's `ClientProcess` type.
protocol ContainerProcess: Sendable {
    /// Starts the process inside the container.
    func start() async throws
    /// Waits for the process to exit and returns its exit code.
    func wait() async throws -> Int32
    /// Sends a signal to the process without waiting for exit.
    func kill(_ signal: Int32) async throws
}

// MARK: - ContainerBackend

/// Abstracts container-daemon interactions for ``ContainerExecutor``.
///
/// The live implementation talks to `com.apple.container.apiserver` via XPC.
/// Tests supply a mock that drives deterministic behaviour without a running daemon.
protocol ContainerBackend: Sendable {
    /// Returns the ``ImageDescription`` for the named OCI reference, pulling if absent.
    func resolveImage(_ reference: String) async throws -> ImageDescription
    /// Creates a new ephemeral container with the given configuration.
    /// The backend is responsible for fetching the default kernel.
    func create(id: String, config: ContainerConfiguration) async throws
    /// Bootstraps the container's init process, connecting the provided file handles
    /// to the process's stdout and stderr, and returns a lifecycle handle.
    func bootstrap(
        id: String,
        stdout: FileHandle,
        stderr: FileHandle
    ) async throws -> any ContainerProcess
    /// Returns current resource statistics for the named container.
    func stats(id: String) async throws -> ContainerStats
    /// Deletes the named container and releases all associated resources.
    func delete(id: String) async throws
}
