#!/bin/bash
# The ASGI executor against uvicorn under wrk, recorded as an artifact.
#
# `bench_asgi.py` is the stdlib-client gate: portable to a CI container, and
# measuring the client as much as the server — it once reported the executor
# at 0.88-0.94x uvicorn where wrk found 0.72x (docs/WSGI_PERFORMANCE.md,
# "The ASGI executor vs uvicorn"). This is the wrk run that produced the
# `asgi-wrk-hello-*.json` artifact docs/BENCHMARKS.md renders, which until
# now had no script behind it. Same shape as bench_layer_split.sh: browser
# headers, keep-alive only, cores MEASURED off the listen socket, byte parity
# asserted before any timing, median of ROUNDS.
#
# Rows:
#   m0serve asgi-executor   zero-config: the per-loop asyncio executor
#   uvicorn asyncio         the repo's standing comparator (`--loop asyncio`)
#   uvicorn uvloop          what `pip install uvicorn[standard]` runs by
#                           default — the number a developer's own machine
#                           produces, so the page can state it
set -u
cd "$(dirname "$0")/.."
OUT=${BENCH_OUT:-/tmp/bench_asgi_wrk.txt}; : > "$OUT"
DUR=${BENCH_DURATION:-8s}
CONNS=${BENCH_CONNS:-16}
ROUNDS=${BENCH_ROUNDS:-3}
COOL=${BENCH_COOLDOWN:-3}
PY=${BENCH_PYTHON:-.venv/bin/python}
# m0serve resolves its interpreter from PATH (README, "Requirements"), so
# put the venv first the way `uv run poe` does: the executor then sees the
# venv's packages -- uvloop among them, which the shim adopts when it can
# import it. Run bare, PATH found the system python3 and every executor row
# recorded before 2026-08-27T18Z ran on stdlib asyncio without saying so;
# the artifact now states both.
export PATH="$PWD/$(dirname "$PY"):$PATH"
# A different build of the server, for an A/B on one box (the uvicorn rows
# are re-measured every run on purpose: they are the drift control).
M0=${M0SERVE_BIN:-bin/m0serve}

HDRS=(-H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
      -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept-Encoding: gzip, deflate, br'
      -H 'Cache-Control: max-age=0' -H 'Upgrade-Insecure-Requests: 1'
      -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' -H 'Referer: http://127.0.0.1:8080/')

field() { echo "$1" | awk -v pat="$2" '$0 ~ pat {print $2; exit}'; }

drain_ports() {
  local waited=0
  while [ "$(netstat -an 2>/dev/null | grep -c TIME_WAIT)" -gt 8000 ]; do
    [ $waited -ge 120 ] && { echo "WARN: TIME_WAIT still high after ${waited}s" | tee -a "$OUT"; return; }
    sleep 10; waited=$((waited + 10))
  done
}

measure() {
  local name=$1
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o /dev/null http://127.0.0.1:8080/ \
    || { echo "$name: never healthy" | tee -a "$OUT"; return; }
  wrk -t2 -c$CONNS -d2s "${HDRS[@]}" http://127.0.0.1:8080/ > /dev/null 2>&1
  local cpu_samples=/tmp/bench_cpu_$$
  ( : > "$cpu_samples"
    while :; do
      lsof -nP -t -iTCP:8080 -sTCP:LISTEN 2>/dev/null | sort -u \
        | xargs ps -o %cpu= -p 2>/dev/null | awk '{s+=$1} END{if (NR>0) print s}' >> "$cpu_samples"
      sleep 1
    done ) & local sampler=$!
  local ka=$(wrk -t2 -c$CONNS -d$DUR --latency "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  kill $sampler 2>/dev/null; wait $sampler 2>/dev/null
  local cores=$(sort -n "$cpu_samples" 2>/dev/null | awk '{a[NR]=$1} END{if (NR>0) printf "%.2f", a[int((NR+1)/2)]/100; else print "?"}')
  rm -f "$cpu_samples"
  local errs=$(echo "$ka" | awk '/Socket errors/ {$1="";$2=""; print; exit}')
  case "$errs" in *connect\ [1-9]*) errs="$errs  <-- MEASUREMENT FAILED (ports)";; esac
  printf '%-26s rps %9s p50 %8s p90 %8s p99 %8s max %8s cores %5s %s\n' "$name" \
    "$(echo "$ka" | awk '/Requests\/sec/ {print $2}')" \
    "$(field "$ka" '^ +50%')" "$(field "$ka" '^ +90%')" "$(field "$ka" '^ +99%')" \
    "$(echo "$ka" | awk '/Latency /{print $4}')" "$cores" "${errs:-}" | tee -a "$OUT"
}

stop() { kill -TERM $pid 2>/dev/null; for q in $(pgrep -P $pid 2>/dev/null); do kill -TERM $q 2>/dev/null; done; wait $pid 2>/dev/null; sleep "$COOL"; }

m0()      { "$M0" bareapp.asgi:application --app-dir apps/asgi_bare --port 8080 > /dev/null 2>&1 & pid=$!; }
uv_loop() { "$PY" -m uvicorn --app-dir apps/asgi_bare --host 127.0.0.1 --port 8080 --log-level critical --loop "$1" bareapp.asgi:application > /dev/null 2>&1 & pid=$!; }

has_uvloop=0
"$PY" -c 'import uvloop' 2>/dev/null && has_uvloop=1
m0_python=$("$M0" --doctor bareapp.asgi:application --app-dir apps/asgi_bare 2>/dev/null \
  | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["python"]["executable"])' 2>/dev/null || echo unknown)
m0_loop=asyncio
[ "$m0_python" != unknown ] && "$m0_python" -c 'import uvloop' 2>/dev/null && m0_loop=uvloop
echo "executor interpreter: $m0_python (loop: $m0_loop)" | tee -a "$OUT"
[ "$has_uvloop" = 1 ] || echo "NOTE: uvloop not importable from $PY - the uvloop row will be skipped" | tee -a "$OUT"

# Byte parity, asserted before any timing.
parity() {
  local tmp=$(mktemp -d)
  m0;                 curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o "$tmp/m0" http://127.0.0.1:8080/; stop
  uv_loop asyncio;    curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o "$tmp/uv" http://127.0.0.1:8080/; stop
  if cmp -s "$tmp/m0" "$tmp/uv"; then
    echo "byte parity m0serve/uvicorn on the bare ASGI app: identical" | tee -a "$OUT"
  else
    echo "byte parity m0serve/uvicorn: DIFFER - rows are not comparable" | tee -a "$OUT"
  fi
  rm -rf "$tmp"
}

drain_ports
parity

for round in $(seq 1 $ROUNDS); do
  m0;              measure "r$round m0serve asgi-executor"; stop
  uv_loop asyncio; measure "r$round uvicorn asyncio";       stop
  if [ "$has_uvloop" = 1 ]; then
    uv_loop uvloop; measure "r$round uvicorn uvloop";       stop
  fi
done
echo "results in $OUT"

python3 "$(dirname "$0")/bench_record.py" asgi_wrk_hello "$OUT" \
  --meta "client=wrk -t2 -c$CONNS -d$DUR, browser headers" --meta "app=apps/asgi_bare" --meta "rounds=$ROUNDS" --meta "server=$M0" \
  --meta "executor_python=$m0_python" --meta "executor_loop=$m0_loop" \
  || echo "WARN: could not write the bench artifact (see above)"
