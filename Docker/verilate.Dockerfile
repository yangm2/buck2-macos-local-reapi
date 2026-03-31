# Minimal verilate-toolchain image: SV/Verilog → C++ codegen only.
#
# Used for the verilate action (verilator codegen stage).
# Does NOT include the C++ compiler toolchain; compile/link actions
# use compile.Dockerfile instead.
#
# Build:  container build -t verilate-toolchain:latest -f Docker/verilate.Dockerfile Docker/
# Verify: container run --rm verilate-toolchain:latest verilator --version

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# TLS certificates (nix installer), curl/xz (nix), python3 (verilator_includer at codegen time)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install nix via the DeterminateSystems installer, which supports running as
# root inside Docker (the upstream nixos.org script refuses root).
# sandbox=false is required in containers (no user namespaces); init=none
# skips the systemd unit that doesn't exist in Docker.
RUN curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix \
        | sh -s -- install linux \
            --extra-conf "sandbox = false" \
            --init none \
            --no-confirm

# Expose nix binaries to subsequent RUN layers and to processes in the container.
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"

# Install Verilator 5.044 from nixpkgs-unstable.
# nixpkgs-unstable tracks verilator closely; Ubuntu 24.04 apt is frozen at 5.020.
RUN nix profile install nixpkgs#verilator

# Symlink nix-installed verilator into /usr/local/bin so it is discoverable
# from the hermetic PATH that REAPI clients (e.g. Buck2 genrule) inject.
# The ENV PATH above helps interactive use, but REAPI Execute actions replace
# the environment entirely with their own hermetic PATH that omits the nix prefix.
RUN ln -sf "$(readlink -f /nix/var/nix/profiles/default/bin/verilator)" /usr/local/bin/verilator

# Verify installation
RUN verilator --version

# Default working directory for REAPI input root
WORKDIR /workspace
