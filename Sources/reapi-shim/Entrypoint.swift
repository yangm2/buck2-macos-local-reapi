import ArgumentParser
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import OSLog

private let logger = Logger(subsystem: "dev.reapi-shim", category: "Startup")

/// Entry point for the `reapi-shim` executable.
///
/// Parses CLI options, wires together the CAS, ActionCache, and
/// ContainerExecutor, then starts a plaintext gRPC server on the configured
/// port serving all four REAPI services (Capabilities, CAS, ActionCache,
/// Execution).
@main
struct REAPIShim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reapi-shim",
        abstract: "Local REAPI server backed by ephemeral Apple Container VMs (Phase 1)"
    )

    @Option(name: .long, help: "Port to listen on")
    var port: Int = 8980

    @Option(name: .long, help: "Directory for the filesystem-backed CAS")
    var casDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/reapi-shim/cas"
    }()

    @Option(name: .long, help: "Directory for the filesystem-backed ActionCache")
    var actionCacheDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/reapi-shim/action-cache"
    }()

    @Option(name: .long, help: "OCI image for the toolchain container")
    var image: String = "verilator-toolchain:latest"

    @Option(name: .long, help: "Path to the container CLI")
    var containerPath: String = "/usr/local/bin/container"

    @Flag(name: .long, help: "Retain the staging directory when an action fails (for post-mortem inspection)")
    var keepFailedStaging: Bool = false

    mutating func run() async throws {
        let casURL = URL(fileURLWithPath: casDir)
        let cas = try ContentAddressableStorage(rootURL: casURL)

        let actionCacheURL = URL(fileURLWithPath: actionCacheDir)
        let cache = try ActionCache(rootURL: actionCacheURL)

        let opStore = OperationStore()
        let executor = ContainerExecutor(
            cas: cas,
            actionCache: cache,
            toolchainImage: image,
            containerPath: containerPath,
            keepFailedStaging: keepFailedStaging
        )

        let server = GRPCServer(
            transport: .http2NIOPosix(
                address: .ipv4(host: "0.0.0.0", port: port),
                transportSecurity: .plaintext
            ),
            services: [
                CapabilitiesService(),
                CASService(cas: cas),
                ActionCacheService(cache: cache),
                ExecutionService(executor: executor, operationStore: opStore)
            ]
        )

        let portVal = port
        let casDirVal = casDir
        let actionCacheDirVal = actionCacheDir
        let imageVal = image
        logger.info("reapi-shim listening on port \(portVal, privacy: .public)")
        logger.info("CAS: \(casDirVal, privacy: .public)")
        logger.info("ActionCache: \(actionCacheDirVal, privacy: .public)")
        logger.info("Image: \(imageVal, privacy: .public)")

        try await server.serve()
    }
}
