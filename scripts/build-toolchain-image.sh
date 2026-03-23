#!/usr/bin/env bash
# Build the Verilator toolchain OCI image for Apple Container VMs.
# Run once before the first `buck2 build`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="${1:-verilator-toolchain:latest}"

echo "Building toolchain image: $IMAGE_NAME"
container build \
    --platform linux/arm64 \
    -t "$IMAGE_NAME" \
    "$REPO_ROOT/Docker"

echo ""
echo "Verifying image..."
container run --rm "$IMAGE_NAME" verilator --version
container run --rm "$IMAGE_NAME" clang++ --version

echo ""
echo "Image ready: $IMAGE_NAME"
