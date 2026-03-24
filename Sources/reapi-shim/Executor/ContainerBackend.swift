import ContainerAPIClient
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

// MARK: - LiveContainerBackend

/// Production ``ContainerBackend`` backed by the `container-apiserver` daemon.
actor LiveContainerBackend: ContainerBackend {
    private let client = ContainerClient()
    /// Cached after first resolution; the image name never changes during a run.
    private var cachedImageDescription: ImageDescription?

    func resolveImage(_ reference: String) async throws -> ImageDescription {
        if let cached = cachedImageDescription { return cached }
        let image = try await ClientImage.get(reference: reference)
        cachedImageDescription = image.description
        return image.description
    }

    func create(id _: String, config: ContainerConfiguration) async throws {
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        try await client.create(configuration: config, options: .default, kernel: kernel)
    }

    func bootstrap(
        id: String,
        stdout: FileHandle,
        stderr: FileHandle
    ) async throws -> any ContainerProcess {
        // ClientProcess (SDK) and ContainerProcess (ours) are structurally identical;
        // bridge via the wrapper below.
        let proc = try await client.bootstrap(id: id, stdio: [nil, stdout, stderr])
        return ClientProcessBridge(wrapped: proc)
    }

    func stats(id: String) async throws -> ContainerStats {
        try await client.stats(id: id)
    }

    func delete(id: String) async throws {
        try await client.delete(id: id, force: true)
    }
}

// MARK: - ClientProcessBridge

/// Wraps an SDK ``ClientProcess`` as a ``ContainerProcess``.
private struct ClientProcessBridge: ContainerProcess {
    let wrapped: any ClientProcess

    func start() async throws {
        try await wrapped.start()
    }

    func wait() async throws -> Int32 {
        try await wrapped.wait()
    }

    func kill(_ signal: Int32) async throws {
        try await wrapped.kill(signal)
    }
}
