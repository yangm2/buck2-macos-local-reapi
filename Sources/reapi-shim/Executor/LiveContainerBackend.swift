import ContainerAPIClient
import ContainerResource
import Foundation

// MARK: - LiveContainerBackend

/// Production ``ContainerBackend`` backed by the `container-apiserver` daemon.
///
/// All methods communicate with the daemon over XPC via ``ContainerClient``.
/// This file is excluded from unit-test coverage because the daemon is not
/// available in the test environment; coverage is provided by `ContainerBackend.swift`
/// (protocol) and `ContainerExecutorTests` (mock-backed executor).
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
