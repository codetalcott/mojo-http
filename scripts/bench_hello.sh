#!/usr/bin/env bash
# Benchmark the raw HTTP hot path (apps/hello) with wrk.
#
# Requires wrk on PATH (deliberately not a dependency of this repo; on
# Debian/Ubuntu: apt-get install wrk). Builds hello, starts it, runs the
# matrix from docs/SERVER_PERFORMANCE.md, prints a summary, and cleans up.
#
# Usage: scripts/bench_hello.sh [duration_seconds]
set -euo pipefail

DUR="${1:-10}s"
BIN="$(mktemp -d)/hello_server"
URL="http://127.0.0.1:8080/"

command -v wrk >/dev/null || { echo "wrk not found on PATH" >&2; exit 1; }

echo "building apps/hello..."
uv run mojo build -I packages/m0-core/ -I packages/m0-http/ \
  apps/hello/server.mojo -o "$BIN"

"$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill -9 $SRV 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -sf -o /dev/null "$URL" && break
  sleep 0.2
done
curl -sf -o /dev/null "$URL" || { echo "server did not come up" >&2; exit 1; }

run() { # label, extra wrk args...
  local label="$1"; shift
  echo "--- $label ---"
  # warm-up
  wrk -d2s "$@" "$URL" >/dev/null 2>&1 || true
  wrk -d"$DUR" --latency "$@" "$URL" | grep -E "Requests/sec|  50%|  99%"
}

run "keep-alive t2/c16"  -t2 -c16
run "keep-alive t2/c64"  -t2 -c64
run "keep-alive t4/c256" -t4 -c256
run "close-mode t2/c16"  -t2 -c16 -H "Connection: close"

echo "done. server pid $SRV will be killed."
