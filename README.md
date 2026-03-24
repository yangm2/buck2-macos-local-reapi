# Local REAPI Shim for Buck2 on macOS

## Introduction

The Local REAPI Shim is a Swift-based implementation of the Remote Execution API (REAPI) server that runs locally on macOS. It enables Buck2 to perform hermetic builds using Apple Containers, providing isolation and reproducibility without requiring a remote REAPI cluster.

This project bridges the gap between Buck2's REAPI client capabilities and local development workflows on macOS, allowing developers to benefit from remote execution semantics (caching, sandboxing, content-addressable storage) in a local environment.

## When to Use It

- You're developing with Buck2 on macOS and want hermetic, reproducible builds
- You need local sandboxing for build actions without setting up a full remote REAPI infrastructure
- You're working on projects that require containerized execution environments
- You want to test REAPI-based workflows locally before deploying to remote clusters
- Your build targets need specific container images or platform properties

## When Not to Use It

- You're not using Buck2 or don't need REAPI functionality
- You're on a non-macOS platform (requires macOS 26+ with Apple Containers)
- You prefer non-hermetic local builds or have existing remote REAPI infrastructure
- Your builds don't require container isolation
- You need features not yet implemented in this local shim

## How to Use It

### Prerequisites

- macOS 26.0 (Tahoe) or later with Apple Containers support
- Xcode 6.2.4+ or Swift 6.2 toolchain
- mise (for managing tool versions)
- protoc 24.4
- SwiftFormat 0.60.1 and SwiftLint 0.63.2 (for development)

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yangm2/buck2-macos-local-reapi.git
   cd buck2-macos-local-reapi
   ```

2. Install dependencies using mise:
   ```bash
   mise install
   ```

3. Build the shim:
   ```bash
   mise run build
   ```

### Running the Shim

Start the REAPI server in debug mode:
```bash
mise run shim-daemon
```

For production use, run the release build:
```bash
mise run shim-daemon:release
```

This will build and launch the shim with default configuration.

### Configuration

The shim can be configured via command-line arguments and environment variables. See the source code in `Sources/reapi-shim/` for available options.

### Integration with Buck2

Configure Buck2 to use the local shim as its REAPI endpoint. Update your `.buckconfig` or Starlark configuration to point to `localhost` on the shim's gRPC port.

Example platform configuration:
```python
# In your BUCK file or platform configuration
remote_execution = {
    "type": "grpc",
    "address": "localhost:50051",  # Default shim port
    "instance_name": "local",
}
```

### Testing

Run the test suite:
```bash
mise run test
```

For end-to-end testing with a real Buck2 project:
```bash
mise run test:e2e
```

See `TESTCASE.md` for details on the Verilator example test case.

## Contributions

We welcome contributions! Please see [DEVELOPMENT.md](DEVELOPMENT.md) for detailed development setup, coding guidelines, and contribution guidelines.

### Quick Development Setup

1. Follow the prerequisites in DEVELOPMENT.md
2. Use `mise run fmt` to format code and `mise run lint` to check style
3. Ensure all tests pass with `mise run test`
4. Submit pull requests with clear descriptions of changes