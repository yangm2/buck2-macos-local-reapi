#!/usr/bin/env bash
# Build OCI toolchain images for the Verilator e2e tests.
#
# Usage:
#   ./scripts/build-toolchain-image.sh              # build combined image (default)
#   ./scripts/build-toolchain-image.sh --all        # build all three images
#   ./scripts/build-toolchain-image.sh <IMAGE_NAME> # build combined image with custom tag
#
# Images:
#   verilator-toolchain:latest  — combined image (all action types); used by e2e test
#   verilate-toolchain:latest   — verilate actions only (nix + verilator + python3)
#   compile-toolchain:latest    — compile/link actions only (apt: clang, g++, make, zlib)
#
# Per-action image selection (verilate-toolchain + compile-toolchain) requires
# `container-image` platform properties in the verilator-example BUCK targets.
# ubuntu:24.04 suffices for test execution (sh_test) actions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_DIR="$REPO_ROOT/Docker"

build_image() {
    local tag="$1"
    local dockerfile="$2"
    echo "Building $tag from $dockerfile ..."
    container build \
        --platform linux/arm64 \
        -t "$tag" \
        -f "$dockerfile" \
        "$DOCKER_DIR"
    echo "  Built: $tag"
}

verify_image() {
    local tag="$1"
    shift
    echo "Verifying $tag ..."
    for cmd in "$@"; do
        container run --rm "$tag" $cmd
    done
}

if [[ "${1:-}" == "--all" ]]; then
    build_image "verilator-toolchain:latest" "$DOCKER_DIR/Dockerfile"
    build_image "verilate-toolchain:latest"  "$DOCKER_DIR/verilate.Dockerfile"
    build_image "compile-toolchain:latest"   "$DOCKER_DIR/compile.Dockerfile"

    echo ""
    verify_image "verilator-toolchain:latest" "verilator --version" "clang++ --version"
    verify_image "verilate-toolchain:latest"  "verilator --version"
    verify_image "compile-toolchain:latest"   "clang++ --version"

    echo ""
    echo "All images ready:"
    echo "  verilator-toolchain:latest  (combined — all actions)"
    echo "  verilate-toolchain:latest   (verilate actions only)"
    echo "  compile-toolchain:latest    (compile/link actions only)"
else
    IMAGE_NAME="${1:-verilator-toolchain:latest}"
    build_image "$IMAGE_NAME" "$DOCKER_DIR/Dockerfile"

    echo ""
    verify_image "$IMAGE_NAME" "verilator --version" "clang++ --version"

    echo ""
    echo "Image ready: $IMAGE_NAME"
fi
