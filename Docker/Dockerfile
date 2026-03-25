# Verilator toolchain image for Apple Container VMs (arm64 Linux)
#
# Installs Verilator 5.044 via nix (nixpkgs-unstable).
# Ubuntu 24.04 apt only ships 5.020 which lacks +1800-2023ext+ support.
#
# Build:  container build -t verilator-toolchain:latest Docker/
# Verify: container run --rm verilator-toolchain:latest verilator --version

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# Install nix prerequisites and the C++ runtime toolchain used by generated Makefiles
RUN apt-get update && apt-get install -y --no-install-recommends \
    # TLS root certificates (required by the nix installer and channel fetches)
    ca-certificates \
    # nix installer prerequisites
    curl \
    xz-utils \
    # C++ toolchain (invoked by Verilator-generated Makefiles at action runtime)
    # g++ is the default $(CXX) in Verilator-generated Makefiles
    clang \
    g++ \
    libstdc++-13-dev \
    make \
    # python3 is used by verilator_includer at compile time
    python3 \
    # zlib1g-dev provides zlib.h required by verilated_fst_c.cpp (FST tracing)
    zlib1g-dev \
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
RUN verilator --version && clang++ --version && make --version

# Default working directory for REAPI input root
WORKDIR /workspace
