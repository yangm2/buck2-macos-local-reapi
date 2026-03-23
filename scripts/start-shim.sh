#!/usr/bin/env bash
# Build and start the local REAPI shim on port 8980.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PORT="${REAPI_PORT:-8980}"
IMAGE="${REAPI_IMAGE:-verilator-toolchain:latest}"
CAS_DIR="${REAPI_CAS_DIR:-$HOME/.local/share/reapi-shim/cas}"

cd "$REPO_ROOT"
swift run --scratch-path /tmp/reapi-shim-build reapi-shim \
    --port "$PORT" \
    --image "$IMAGE" \
    --cas-dir "$CAS_DIR"
