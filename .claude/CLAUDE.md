## Coding Guidelines
- code must be lint clean
- code must be fmt clean
- code must pass all the tests
- code should be idiomatic
- code should follow SOLID principles
- documentation should be kept up-to-date

## System & Tools
- don't use brew/homebrew
- don't use Docker
- do use Apple Containers
- do use nix for native tools
- do install/run tools inside Apple containers
- don't use nix for Python tooling
- do use uv for Python tooling
- don't use nix for Rust tooling
- do use cargo for Rust tooling

## Workflows
Tasks are managed via `mise`. Run `mise tasks` to list all available tasks.

| Task | Command | Description |
|------|---------|-------------|
| Format | `mise run fmt` | Format all Swift sources in-place (swiftformat) |
| Format check | `mise run fmt:check` | Check formatting without modifying files — use for CI |
| Lint | `mise run lint` | Lint all Swift sources (swiftlint --strict) |
| Test | `mise run test` | Run the full test suite (`swift test`) |
| Build | `mise run build` | Build the shim in debug mode (`swift build`) |
| Run | `mise run run` | Build and start the shim with default options |
| Clean spill | `mise run clean:spill` | Remove Swift index-build artefacts spilled to repo root |
| Clean | `mise run clean` | Full clean: spill artefacts + `.build/` directory |

Before committing, ensure `fmt:check`, `lint`, and `test` all pass.

## Tool Versions
Pinned versions — verify against upstream before bumping.

| Tool | Version | Upstream |
|------|---------|----------|
| swiftformat | 0.60.1 | https://github.com/nicklockwood/SwiftFormat/releases |
| swiftlint | 0.63.2 | https://github.com/realm/SwiftLint/releases |
| protoc | 24.4 | https://github.com/protocolbuffers/protobuf/releases |
| grpc-swift | 2.2.3 (migrate to [grpc-swift-2](https://github.com/grpc/grpc-swift-2) ≥ 2.3.0 in Phase 1 — original repo is maintenance-only after 2.2.3) | https://github.com/grpc/grpc-swift/releases |
| grpc-swift-protobuf | 2.2.1 | https://github.com/grpc/grpc-swift-protobuf/releases |
| grpc-swift-nio-transport | 2.5.0 | https://github.com/grpc/grpc-swift-nio-transport/releases |
| swift-argument-parser | 1.7.1 | https://github.com/apple/swift-argument-parser/releases |
| actions/checkout | v6 | https://github.com/actions/checkout/releases |
| jdx/mise-action | v4 | https://github.com/jdx/mise-action/releases |
