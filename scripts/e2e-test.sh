#!/usr/bin/env bash
# End-to-end test: build a genrule through the local REAPI shim.
#
# Prerequisites (not managed here):
#   - buck2 on PATH
#   - Apple Container runtime available
#   - Container image present (default: ubuntu:24.04)
#
# The test is structured in two phases:
#   1. Cold build — action runs inside a container; output is verified.
#   2. Warm build — ActionCache hit; zero actions executed.
#
# On success the test cleans up after itself (buck-out, CAS dir).
# On failure everything is left in place for debugging.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/Tests/E2E/hello-genrule"

REAPI_IMAGE="${REAPI_IMAGE:-ubuntu:24.04}"
REAPI_PORT="${REAPI_PORT:-8980}"

# Temp directories — created below, cleaned up only on success.
CAS_DIR=""
SHIM_LOG=""
SHIM_PID=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo "[e2e] $*"; }
ok()    { echo "[e2e] ✓ $*"; }
fail()  { echo "[e2e] ✗ $*" >&2; exit 1; }

cleanup_on_success() {
    info "Cleaning up..."
    [[ -n "$SHIM_PID" ]] && kill "$SHIM_PID" 2>/dev/null || true
    [[ -n "$CAS_DIR"  ]] && rm -rf "$CAS_DIR"
    [[ -n "$SHIM_LOG" ]] && rm -f  "$SHIM_LOG"
    rm -rf "$FIXTURE_DIR/buck-out"
    ok "All clean."
}

stop_shim() {
    [[ -n "$SHIM_PID" ]] && kill "$SHIM_PID" 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# Step 1 — ensure buck2 is available
# ---------------------------------------------------------------------------

if ! command -v buck2 &>/dev/null; then
    fail "buck2 not found on PATH. Install it before running e2e tests."
fi
info "Using buck2: $(buck2 --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# Step 2 — resolve prelude commit from the installed buck2 version
# ---------------------------------------------------------------------------
#
# Each buck2 GitHub release ships a 'prelude_hash' file containing the exact
# prelude commit SHA compatible with that binary.  We derive the calver from
# 'buck2 --version' so there is nothing to pin manually — just upgrade buck2
# and re-run; the prelude will follow automatically.

BUCK2_VERSION="$(buck2 --version 2>&1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
[[ -n "$BUCK2_VERSION" ]] || fail "Could not parse calver from 'buck2 --version'."
info "buck2 version: $BUCK2_VERSION"

PRELUDE_HASH_URL="https://github.com/facebook/buck2/releases/download/${BUCK2_VERSION}/prelude_hash"
PRELUDE_COMMIT="$(curl -fsSL "$PRELUDE_HASH_URL" | tr -d '[:space:]')"
[[ -n "$PRELUDE_COMMIT" ]] || fail "Could not fetch prelude_hash from $PRELUDE_HASH_URL"
info "Prelude commit: $PRELUDE_COMMIT"

PRELUDE_DIR="$FIXTURE_DIR/prelude"
if [[ ! -d "$PRELUDE_DIR/.git" ]]; then
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
        info "Prelude at $CURRENT, updating to $PRELUDE_COMMIT..."
        git -C "$PRELUDE_DIR" fetch --depth=1 origin "$PRELUDE_COMMIT"
        git -C "$PRELUDE_DIR" checkout "$PRELUDE_COMMIT"
        ok "Prelude updated."
    else
        info "Prelude already at correct commit."
    fi
fi

# ---------------------------------------------------------------------------
# Step 3 — build the shim
# ---------------------------------------------------------------------------

info "Building reapi-shim..."
cd "$REPO_ROOT"
PROTOC_PATH="$(which protoc)" swift build --product reapi-shim 2>&1 | tail -5
SHIM_BIN="$(swift build --show-bin-path 2>/dev/null)/reapi-shim"
ok "Shim built: $SHIM_BIN"

# ---------------------------------------------------------------------------
# Step 4 — start the shim in the background
# ---------------------------------------------------------------------------

CAS_DIR="$(mktemp -d)"
SHIM_LOG="$(mktemp)"
info "Starting shim (image=$REAPI_IMAGE, port=$REAPI_PORT, cas=$CAS_DIR)..."
"$SHIM_BIN" \
    --port "$REAPI_PORT" \
    --image "$REAPI_IMAGE" \
    --cas-dir "$CAS_DIR" \
    >"$SHIM_LOG" 2>&1 &
SHIM_PID=$!
trap stop_shim EXIT

wait_for_port "$REAPI_PORT"
ok "Shim is listening."

# ---------------------------------------------------------------------------
# Step 5 — cold build (action must execute in a container)
# ---------------------------------------------------------------------------

cd "$FIXTURE_DIR"
info "Cold build: buck2 build //:hello"
buck2 clean 2>/dev/null || true
COLD_OUTPUT="$(buck2 build //:hello 2>&1)"
echo "$COLD_OUTPUT"

HELLO_TXT="$(buck2 build //:hello --show-output 2>/dev/null | awk '{print $2}')"
[[ -f "$HELLO_TXT" ]] || fail "Output file not found: $HELLO_TXT"

CONTENT="$(cat "$HELLO_TXT")"
EXPECTED="hello from local REAPI"
if [[ "$CONTENT" != *"$EXPECTED"* ]]; then
    fail "Unexpected output: '$CONTENT' (expected to contain '$EXPECTED')"
fi
ok "Cold build output: '$CONTENT'"

# ---------------------------------------------------------------------------
# Step 6 — warm build (must be an ActionCache hit after wiping buck-out)
# ---------------------------------------------------------------------------
#
# buck2 clean removes buck-out so the next build cannot reuse local artifacts.
# Buck2 then queries the shim's ActionCache; on a hit it reports the action as
# "cached" (Commands: 1, cached: 1, remote: 0) rather than re-executing it.
# Buck2 omits the Commands line entirely when zero commands run (e.g. nothing
# changed on disk), so we fail only when a non-zero remote execution appears.

info "Warm build: wiping buck-out then rebuilding (expect ActionCache hit)"
buck2 clean 2>/dev/null || true
WARM_OUTPUT="$(buck2 build //:hello 2>&1)"
echo "$WARM_OUTPUT"

if echo "$WARM_OUTPUT" | grep -qE "remote:[[:space:]]*[1-9]"; then
    fail "Warm build executed remotely — ActionCache miss. Check shim logs: $SHIM_LOG"
fi
ok "Warm build: no remote execution (ActionCache hit)."

# ---------------------------------------------------------------------------
# All assertions passed — clean up
# ---------------------------------------------------------------------------

stop_shim
trap - EXIT
cleanup_on_success
ok "E2E test passed."
