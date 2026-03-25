# Local REAPI Shim for Buck2 on macOS

## Introduction

The Local REAPI Shim is a Swift-based REAPI server that runs locally on macOS. It enables Buck2 to perform hermetic builds using [Apple Containers](https://github.com/apple/container), providing container-level isolation and reproducibility without a remote REAPI cluster.

Each build action runs inside an ephemeral Linux VM (via `Virtualization.framework`), with inputs staged via VirtioFS and outputs collected back into a local content-addressable store. The ActionCache persists results across builds so unchanged actions are never re-executed.

## Requirements

- macOS 26.0 (Tahoe) or later
- Xcode 26+ (Swift 6.2 — **must use the Xcode-bundled toolchain**, not swift.org)
- Apple Containers runtime (`container-apiserver` launch agent)
- [mise](https://mise.jdx.dev/) for tool version management

## Quick Start

```sh
# 1. Install pinned tools (swiftformat, swiftlint, protoc)
mise install

# 2. Build
mise run build

# 3. Start the shim (debug)
mise run shim-daemon
```

The shim listens on `grpc://localhost:8980` by default.

## Configuration

### `.buckconfig` (or `.buckconfig.local`)

```ini
[build]
execution_platforms = root//platforms:default

[buck2_re_client]
engine_address       = grpc://localhost:8980
action_cache_address = grpc://localhost:8980
cas_address          = grpc://localhost:8980
instance_name        = default
tls                  = false

[buck2]
digest_algorithms = SHA256
```

### Execution platform (`platforms/defs.bzl`)

```python
CommandExecutorConfig(
    local_enabled  = False,   # all actions go through the shim
    remote_enabled = True,
    remote_execution_properties = {
        "OSFamily": "linux",
        "ISA":      "aarch64",
    },
    remote_execution_use_case = "buck2-default",
)
```

### Selecting a container image per action

The shim reads the standard `container-image` platform property to choose which OCI image to run each action in. If the property is absent, `--image` is used as the default.

```python
# In platforms/defs.bzl — per-action image selection
CommandExecutorConfig(
    remote_execution_properties = {
        "OSFamily":        "linux",
        "container-image": "docker://verilator-toolchain:latest",
    },
)
```

Both bare names (`ubuntu:24.04`) and the `docker://` scheme are accepted.

### CLI options

| Option | Default | Description |
|---|---|---|
| `--port` | `8980` | gRPC listen port |
| `--image` | `verilator-toolchain:latest` | Default OCI image when `container-image` platform property is absent |
| `--cas-dir` | `~/.local/share/reapi-shim/cas` | Filesystem CAS root |
| `--action-cache-dir` | `~/.local/share/reapi-shim/action-cache` | ActionCache root |
| `--keep-failed-staging` | off | Preserve staging dir on failure for post-mortem |
| `--remote-endpoint` | — | Upstream REAPI endpoint for remote dispatch |
| `--path-prefix` | — | Extra path(s) prepended to `PATH` inside containers (escape hatch — see below) |

## Container image requirements

Buck2 injects a hermetic `PATH` into every action:

```
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**Best practice:** symlink every build tool into `/usr/local/bin` inside your image so it is reachable from this path regardless of where the package manager installs it:

```dockerfile
# Example: tool installed by nix into a non-standard prefix
RUN ln -sf "$(readlink -f /nix/var/nix/profiles/default/bin/mytool)" /usr/local/bin/mytool
```

**Escape hatch:** if you cannot modify the image, use `--path-prefix` to prepend additional directories to the container's `PATH`:

```sh
reapi-shim --image my-image:latest \
           --path-prefix /nix/var/nix/profiles/default/bin
```

Prefer the Dockerfile approach — `--path-prefix` is specific to this shim and won't help with standard RE servers (BuildBuddy, BuildBarn, etc.).

## Testing

```sh
mise run test           # unit tests
mise run test:e2e       # basic genrule e2e (requires buck2, ubuntu:24.04 image)
mise run test:e2e:verilator  # realistic Verilator e2e (requires verilator-toolchain image)
mise run test:coverage  # unit tests + per-file coverage report
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for full setup, coding guidelines, and architecture documentation.

## Contributions

Please follow the guidelines in [DEVELOPMENT.md](DEVELOPMENT.md). Before opening a PR, ensure:

```sh
mise run fmt:check
mise run lint
mise run test
```
