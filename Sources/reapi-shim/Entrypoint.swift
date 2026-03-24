import ArgumentParser
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

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
        abstract: "Local REAPI server backed by ephemeral Apple Container VMs (Phase 0)"
    )

    @Option(name: .long, help: "Port to listen on")
    var port: Int = 8980

    @Option(name: .long, help: "Directory for the filesystem-backed CAS")
    var casDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/reapi-shim/cas"
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
        let cache = ActionCache()
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

        print("reapi-shim listening on port \(port)")
        print("CAS: \(casDir)")
        print("Image: \(image)")

        try await server.serve()
    }
}
