#!/usr/bin/env bash
# Realistic end-to-end test: build and test a Verilator design through the
# local REAPI shim, using the verilator-example repository (for-shim branch).
#
# Prerequisites (not managed by this script):
#   - buck2 on PATH
#   - Apple Container runtime running
#   - verilator-toolchain image built (run: ./scripts/build-toolchain-image.sh)
#
# Environment variables:
#   VERILATOR_EXAMPLE_DIR   path to a verilator-example checkout on the
#                           for-shim branch.  Defaults to the sibling directory
#                           ../verilator-example relative to this repo.
#                           If the directory does not exist the repo is cloned
#                           from GitHub automatically.
#   REAPI_IMAGE             container image the shim executes actions in.
#                           (default: verilator-toolchain:latest)
#   REAPI_PORT              shim gRPC port (default: 8980)
#
# Test phases:
#   1. Cold build — verilator SV→C++ codegen + compile + link inside a VM.
#   2. Test run — buck2 test //src:sim99 //src:sim100 via REAPI shim.
#   3. Warm build — ActionCache hit after buck2 clean; zero remote actions.
#   4. Warm test — tests re-executed; verify still pass.
#   5. ActionCache persistence — restart shim with same on-disk state;
#      rebuild must still be a cache hit.
#
# On success the script cleans up after itself.
# On failure everything is left in place for debugging.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REAPI_IMAGE="${REAPI_IMAGE:-verilator-toolchain:latest}"
REAPI_PORT="${REAPI_PORT:-8980}"

VERILATOR_EXAMPLE_DIR="${VERILATOR_EXAMPLE_DIR:-$(cd "$REPO_ROOT/.." && pwd)/verilator-example}"

SHIM_PID=""
SHIM_LOG=""
SHIM_LOG2=""
CAS_DIR=""
AC_DIR=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo "[e2e-verilator] $*"; }
ok()    { echo "[e2e-verilator] ✓ $*"; }
fail()  { echo "[e2e-verilator] ✗ $*" >&2; exit 1; }

cleanup_on_success() {
    info "Cleaning up..."
    stop_shim
    buck2 -C "$VERILATOR_EXAMPLE_DIR" clean 2>/dev/null || true
    rm -f  "$VERILATOR_EXAMPLE_DIR/.buckconfig.local"
    [[ -n "$CAS_DIR"   ]] && rm -rf "$CAS_DIR"
    [[ -n "$AC_DIR"    ]] && rm -rf "$AC_DIR"
    [[ -n "$SHIM_LOG"  ]] && rm -f  "$SHIM_LOG"
    [[ -n "$SHIM_LOG2" ]] && rm -f  "$SHIM_LOG2"
    ok "All clean."
}

stop_shim() {
    [[ -n "$SHIM_PID" ]] && kill "$SHIM_PID" 2>/dev/null || true
    SHIM_PID=""
}

wait_for_port() {
    local port="$1" attempts=30
    info "Waiting for shim on port $port..."
    for ((i = 0; i < attempts; i++)); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    fail "Shim did not open port $port after ${attempts} attempts."
}

wait_port_closed() {
    local port="$1" attempts=20
    for ((i = 0; i < attempts; i++)); do
        nc -z 127.0.0.1 "$port" 2>/dev/null || return 0
        sleep 0.25
    done
    fail "Port $port still open after ${attempts} attempts."
}

start_shim() {
    local log="$1"
    STALE_PIDS="$(lsof -ti ":$REAPI_PORT" 2>/dev/null || true)"
    if [[ -n "$STALE_PIDS" ]]; then
        info "Killing stale process(es) on port $REAPI_PORT: $STALE_PIDS"
        echo "$STALE_PIDS" | xargs kill -9 2>/dev/null || true
        sleep 0.5
    fi
    info "Starting shim (image=$REAPI_IMAGE, port=$REAPI_PORT, cas=$CAS_DIR)..."
    "$SHIM_BIN" \
        --port "$REAPI_PORT" \
        --image "$REAPI_IMAGE" \
        --cas-dir "$CAS_DIR" \
        --action-cache-dir "$AC_DIR" \
        >"$log" 2>&1 &
    SHIM_PID=$!
    trap stop_shim EXIT
    wait_for_port "$REAPI_PORT"
    ok "Shim is listening (pid=$SHIM_PID)."
}

# ---------------------------------------------------------------------------
# Step 1 — prerequisites
# ---------------------------------------------------------------------------

if ! command -v buck2 &>/dev/null; then
    fail "buck2 not found on PATH. Install it before running e2e tests."
fi
info "Using buck2: $(buck2 --version 2>&1 | head -1)"

if ! container image inspect "$REAPI_IMAGE" &>/dev/null; then
    fail "Container image '$REAPI_IMAGE' not found. Build it first:
  $REPO_ROOT/scripts/build-toolchain-image.sh"
fi
ok "Toolchain image: $REAPI_IMAGE"

# ---------------------------------------------------------------------------
# Step 2 — locate / clone verilator-example at for-shim
# ---------------------------------------------------------------------------

if ! git -C "$VERILATOR_EXAMPLE_DIR" rev-parse --git-dir &>/dev/null; then
    info "Cloning verilator-example (for-shim branch) to $VERILATOR_EXAMPLE_DIR ..."
    git clone \
        --branch for-shim \
        https://github.com/yangm2/verilator-example.git \
        "$VERILATOR_EXAMPLE_DIR"
    ok "Cloned."
else
    CURRENT_BRANCH="$(git -C "$VERILATOR_EXAMPLE_DIR" rev-parse --abbrev-ref HEAD)"
    if [[ "$CURRENT_BRANCH" != "for-shim" ]]; then
        fail "verilator-example at $VERILATOR_EXAMPLE_DIR is on branch '$CURRENT_BRANCH', expected 'for-shim'.
  Run: git -C \"$VERILATOR_EXAMPLE_DIR\" checkout for-shim"
    fi
    info "Using $VERILATOR_EXAMPLE_DIR (branch: for-shim, $(git -C "$VERILATOR_EXAMPLE_DIR" rev-parse --short HEAD))"
fi

# ---------------------------------------------------------------------------
# Step 3 — resolve and sync buck2 prelude
# ---------------------------------------------------------------------------

BUCK2_VERSION="$(buck2 --version 2>&1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
[[ -n "$BUCK2_VERSION" ]] || fail "Could not parse calver from 'buck2 --version'."
info "buck2 version: $BUCK2_VERSION"

PRELUDE_HASH_URL="https://github.com/facebook/buck2/releases/download/${BUCK2_VERSION}/prelude_hash"
PRELUDE_COMMIT="$(curl -fsSL "$PRELUDE_HASH_URL" | tr -d '[:space:]')"
[[ -n "$PRELUDE_COMMIT" ]] || fail "Could not fetch prelude_hash from $PRELUDE_HASH_URL"
info "Prelude commit: $PRELUDE_COMMIT"

PRELUDE_DIR="$VERILATOR_EXAMPLE_DIR/prelude"
if ! git -C "$PRELUDE_DIR" rev-parse --git-dir &>/dev/null; then
    info "Cloning buck2 prelude..."
    git clone --depth=1 \
        https://github.com/facebook/buck2-prelude.git \
        "$PRELUDE_DIR"
    git -C "$PRELUDE_DIR" fetch --depth=1 origin "$PRELUDE_COMMIT"
    git -C "$PRELUDE_DIR" checkout "$PRELUDE_COMMIT"
    ok "Prelude cloned at $PRELUDE_COMMIT."
else
    CURRENT="$(git -C "$PRELUDE_DIR" rev-parse HEAD)"
    if [[ "$CURRENT" != "$PRELUDE_COMMIT" ]]; then
        info "Updating prelude $CURRENT → $PRELUDE_COMMIT..."
        git -C "$PRELUDE_DIR" fetch --depth=1 origin "$PRELUDE_COMMIT"
        git -C "$PRELUDE_DIR" checkout "$PRELUDE_COMMIT"
        ok "Prelude updated."
    else
        info "Prelude already at correct commit."
    fi
fi

# ---------------------------------------------------------------------------
# Step 4 — inject .buckconfig.local
# ---------------------------------------------------------------------------
#
# The for-shim .buckconfig intentionally omits RE addresses so the repo works
# without a shim for non-remote workflows.  Inject them via .buckconfig.local,
# which Buck2 merges at startup and which is .gitignored by convention.

cat > "$VERILATOR_EXAMPLE_DIR/.buckconfig.local" <<EOF
[build]
execution_platforms = root//platforms:default

[buck2_re_client]
engine_address       = grpc://localhost:${REAPI_PORT}
action_cache_address = grpc://localhost:${REAPI_PORT}
cas_address          = grpc://localhost:${REAPI_PORT}
instance_name        = default
tls                  = false

[buck2]
digest_algorithms = SHA256
EOF
ok "Injected .buckconfig.local (RE → grpc://localhost:${REAPI_PORT})"

# ---------------------------------------------------------------------------
# Step 5 — build the shim
# ---------------------------------------------------------------------------

info "Building reapi-shim..."
cd "$REPO_ROOT"
PROTOC_PATH="$(which protoc)" swift build --product reapi-shim 2>&1 | tail -5
SHIM_BIN="$(swift build --show-bin-path 2>/dev/null)/reapi-shim"
ok "Shim built: $SHIM_BIN"

CAS_DIR="$(mktemp -d)"
AC_DIR="$(mktemp -d)"
SHIM_LOG="$(mktemp)"

# ---------------------------------------------------------------------------
# Step 6 — cold build (verilator SV→C++→binary, all inside container VMs)
# ---------------------------------------------------------------------------

start_shim "$SHIM_LOG"

cd "$VERILATOR_EXAMPLE_DIR"
buck2 clean 2>/dev/null || true

info "Cold build: buck2 build //src:Vhello_world"
buck2 build //src:Vhello_world 2>&1 | tee /dev/stderr | cat

VHELLO="$(buck2 build //src:Vhello_world --show-output 2>/dev/null | awk '{print $2}')"
[[ -x "$VHELLO" ]] || fail "Vhello_world binary not found or not executable: $VHELLO"
ok "Cold build: Vhello_world binary produced at $VHELLO"

# ---------------------------------------------------------------------------
# Step 7 — test run (sim99, sim100 must pass)
# ---------------------------------------------------------------------------

info "Running tests: buck2 test //src:sim99 //src:sim100"
buck2 test //src:sim99 //src:sim100 2>&1 | tee /dev/stderr | cat
ok "Tests passed: sim99, sim100"

# ---------------------------------------------------------------------------
# Step 8 — warm build (ActionCache hit after buck2 clean)
# ---------------------------------------------------------------------------

info "Warm build: wiping buck-out (expect ActionCache hit)"
buck2 clean 2>/dev/null || true
WARM_OUTPUT="$(buck2 build //src:Vhello_world 2>&1)"
echo "$WARM_OUTPUT"

if echo "$WARM_OUTPUT" | grep -qE "remote:[[:space:]]*[1-9]"; then
    fail "Warm build executed remotely — ActionCache miss. Shim log: $SHIM_LOG"
fi
ok "Warm build: no remote execution (ActionCache hit)."

# ---------------------------------------------------------------------------
# Step 9 — warm test run
# ---------------------------------------------------------------------------

info "Warm test run: re-running tests after buck2 clean"
buck2 clean 2>/dev/null || true
buck2 test //src:sim99 //src:sim100 2>&1 | tee /dev/stderr | cat
ok "Warm test run passed."

# ---------------------------------------------------------------------------
# Step 10 — ActionCache persistence across shim restart
# ---------------------------------------------------------------------------

info "Restarting shim to validate ActionCache persistence..."
stop_shim
wait_port_closed "$REAPI_PORT"

SHIM_LOG2="$(mktemp)"
start_shim "$SHIM_LOG2"

buck2 clean 2>/dev/null || true
PERSIST_OUTPUT="$(buck2 build //src:Vhello_world 2>&1)"
echo "$PERSIST_OUTPUT"

if echo "$PERSIST_OUTPUT" | grep -qE "remote:[[:space:]]*[1-9]"; then
    fail "Persistence build executed remotely — ActionCache not persisted. Log: $SHIM_LOG2"
fi
ok "ActionCache persisted across shim restart."

# ---------------------------------------------------------------------------
# All assertions passed — clean up
# ---------------------------------------------------------------------------

stop_shim
trap - EXIT
cleanup_on_success
ok "Verilator E2E test passed."
