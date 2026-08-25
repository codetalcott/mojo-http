#!/bin/bash
# Where does the Granian gap live: the HTTP layer, or the WSGI bridge?
#
# docs/WSGI_PERFORMANCE.md measured Granian 2.8.1 at 1.4-2.0x either mojo-http
# mode on the same free-threaded interpreter, serving a byte-identical
# response. That is one number for two possible causes, and they have
# completely different fixes. This script splits it into three rows that
# differ by exactly one layer each:
#
#   1. apps/hello       Mojo handler, ZERO Python   -> mojo-http's HTTP ceiling
#                       (single process: that app has no WorkerSupervisor)
#   2. m0serve + bare   the same HTTP layer + the WSGI bridge
#   3. granian + bare   Granian's HTTP layer + its PyO3 bridge
#
# Rows 2 and 3 run the SAME application (apps/wsgi_bare, a plain PEP 3333
# callable with no third-party imports) so the Python work is identical. The
# bare app is used rather than Django on purpose: Django's middleware stack is
# a large constant both servers pay, and it compresses the ratio that this
# script exists to resolve. All three roots return 13 bytes of text/plain.
#
# Reading it:
#   (1) - (2)  is mojo-http's own bridge cost
#   (2) vs (3) is the head-to-head on identical Python work
#   (1) vs (3) says whether mojo-http's HTTP ceiling is even above what
#              Granian delivers THROUGH a Python bridge - if it is not, the
#              gap is in the HTTP layer and the bridge is a red herring
#
# Keep-alive only, with a cooldown and a TIME_WAIT gate: see the methodology
# note in docs/WSGI_PERFORMANCE.md for why a close-per-request run in the same
# script would poison every row after the first.
set -u
cd "$(dirname "$0")/.."
OUT=${BENCH_OUT:-/tmp/bench_layer_split.txt}; : > "$OUT"
DUR=${BENCH_DURATION:-10s}
CONNS=${BENCH_CONNS:-16}
ROUNDS=${BENCH_ROUNDS:-3}
COOL=${BENCH_COOLDOWN:-5}
HELLO=${HELLO_BIN:-/tmp/bench_hello_server}

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
  wrk -t2 -c$CONNS -d3s "${HDRS[@]}" http://127.0.0.1:8080/ > /dev/null 2>&1
  local ka=$(wrk -t2 -c$CONNS -d$DUR --latency "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  local errs=$(echo "$ka" | awk '/Socket errors/ {$1="";$2=""; print; exit}')
  case "$errs" in *connect\ [1-9]*) errs="$errs  <-- MEASUREMENT FAILED (ports)";; esac
  printf '%-26s rps %9s p50 %8s p90 %8s p99 %8s max %8s %s\n' "$name" \
    "$(echo "$ka" | awk '/Requests\/sec/ {print $2}')" \
    "$(field "$ka" '^ +50%')" "$(field "$ka" '^ +90%')" "$(field "$ka" '^ +99%')" \
    "$(echo "$ka" | awk '/Latency /{print $4}')" "${errs:-}" | tee -a "$OUT"
}

stop() { kill -TERM $pid 2>/dev/null; for q in $(pgrep -P $pid 2>/dev/null); do kill -TERM $q 2>/dev/null; done; wait $pid 2>/dev/null; sleep "$COOL"; }

# Byte parity across all three, asserted before any timing.
parity() {
  local tmp=$(mktemp -d)
  M0_PORT=8080 "$HELLO" > /dev/null 2>&1 & pid=$!
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o "$tmp/hello" http://127.0.0.1:8080/; stop
  bin/m0serve bareapp.wsgi:application --app-dir apps/wsgi_bare --port 8080 --workers 1 > /dev/null 2>&1 & pid=$!
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o "$tmp/m0" http://127.0.0.1:8080/; stop
  ( cd apps/wsgi_bare && exec ../../.venv/bin/granian --interface wsgi --workers 1 \
      --blocking-threads 1 --host 127.0.0.1 --port 8080 --log-level warning \
      bareapp.wsgi:application ) > /dev/null 2>&1 & pid=$!
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o "$tmp/gr" http://127.0.0.1:8080/; stop
  echo "sizes: hello=$(wc -c < "$tmp/hello" | tr -d ' ') m0serve=$(wc -c < "$tmp/m0" | tr -d ' ') granian=$(wc -c < "$tmp/gr" | tr -d ' ')" | tee -a "$OUT"
  if cmp -s "$tmp/m0" "$tmp/gr"; then
    echo "byte parity m0serve/granian on the bare app: identical" | tee -a "$OUT"
  else
    echo "byte parity m0serve/granian: DIFFER — rows 2 and 3 are not comparable" | tee -a "$OUT"
  fi
  rm -rf "$tmp"
}

if [ ! -x .venv/bin/granian ]; then
  echo "NOTE: granian rows will be skipped - install the pinned comparator with: uv sync --group bench" | tee -a "$OUT"
fi

drain_ports
parity

for round in $(seq 1 $ROUNDS); do
  # apps/hello has no WorkerSupervisor — it never forks, so M0_WORKERS is inert
  # there and it is measured once per round as the single-process row it is.
  # (An earlier version of this script ran it at "w1" and "w4" and got
  # identical numbers, which is not a scaling result, just the same server
  # twice.)
  M0_PORT=8080 "$HELLO" > /dev/null 2>&1 & pid=$!
  measure "r$round hello(no python,1proc)"; stop
  for n in 1 4; do
    bin/m0serve bareapp.wsgi:application --app-dir apps/wsgi_bare --port 8080 --workers $n > /dev/null 2>&1 & pid=$!
    measure "r$round m0serve+bare w$n"; stop
    if [ -x .venv/bin/granian ]; then
      ( cd apps/wsgi_bare && exec ../../.venv/bin/granian --interface wsgi --workers $n \
          --blocking-threads 1 --host 127.0.0.1 --port 8080 --log-level warning \
          bareapp.wsgi:application ) > /dev/null 2>&1 & pid=$!
      measure "r$round granian+bare w$n"; stop
    fi
  done
done
echo "results in $OUT"
