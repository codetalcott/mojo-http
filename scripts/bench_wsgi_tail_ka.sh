#!/bin/bash
# The keep-alive tail alone, replicated — the focused half of
# scripts/bench_wsgi_tail.sh.
#
# The full script's close-per-request runs open ~160k connections each, and a
# long session exhausts the ephemeral port range: rows late in a run come back
# with no numbers at all (TIME_WAIT, not a server fault). The tail question is
# a keep-alive question, so this script drops the close runs, adds a cooldown
# between rows, and repeats each configuration enough times to tell a real
# difference from a noisy one.
set -u
cd "$(dirname "$0")/.."
OUT=${BENCH_OUT:-/tmp/bench_wsgi_tail_ka.txt}; : > "$OUT"
DUR=${BENCH_DURATION:-10s}
CONNS=${BENCH_CONNS:-16}
ROUNDS=${BENCH_ROUNDS:-3}
COOL=${BENCH_COOLDOWN:-5}

HDRS=(-H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
      -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept-Encoding: gzip, deflate, br'
      -H 'Cache-Control: max-age=0' -H 'Upgrade-Insecure-Requests: 1'
      -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' -H 'Referer: http://127.0.0.1:8080/')

field() { echo "$1" | awk -v pat="$2" '$0 ~ pat {print $2; exit}'; }

# macOS's ephemeral range is 49152-65535 — 16384 ports — and a close-per-request
# benchmark run just before this one can leave every one of them in TIME_WAIT.
# wrk then cannot open even its 16 keep-alive connections and the row reads
# `connect 16` with no numbers. Wait for the range to drain rather than
# measure through it; MSL on macOS is 15s, so this is normally seconds.
drain_ports() {
  local waited=0
  while [ "$(netstat -an 2>/dev/null | grep -c TIME_WAIT)" -gt 8000 ]; do
    [ $waited -ge 120 ] && { echo "WARN: TIME_WAIT still high after ${waited}s; rows may be unreliable" | tee -a "$OUT"; return; }
    sleep 10; waited=$((waited + 10))
  done
  [ $waited -gt 0 ] && echo "(waited ${waited}s for TIME_WAIT to drain)" | tee -a "$OUT"
}
drain_ports

measure() {
  local name=$1
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o /dev/null http://127.0.0.1:8080/ \
    || { echo "$name: never healthy" | tee -a "$OUT"; return; }
  wrk -t2 -c$CONNS -d3s "${HDRS[@]}" http://127.0.0.1:8080/ > /dev/null 2>&1
  local ka=$(wrk -t2 -c$CONNS -d$DUR --latency "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  # Socket errors are reported, not swallowed: a row with no numbers is a
  # measurement failure (usually TIME_WAIT), and it must not read as a slow
  # server. The full-run version of this table had five such rows.
  local errs=$(echo "$ka" | awk '/Socket errors/ {$1="";$2=""; print; exit}')
  # A row that could not connect is a failed measurement, not a slow server.
  case "$errs" in *connect\ [1-9]*) errs="$errs  <-- MEASUREMENT FAILED (ports)";; esac
  printf '%-24s rps %9s p50 %8s p90 %8s p99 %8s max %8s %s\n' "$name" \
    "$(echo "$ka" | awk '/Requests\/sec/ {print $2}')" \
    "$(field "$ka" '^ +50%')" "$(field "$ka" '^ +90%')" "$(field "$ka" '^ +99%')" \
    "$(echo "$ka" | awk '/Latency /{print $4}')" "${errs:-}" | tee -a "$OUT"
}

stop() { kill -TERM $pid 2>/dev/null; for q in $(pgrep -P $pid 2>/dev/null); do kill -TERM $q 2>/dev/null; done; wait $pid 2>/dev/null; sleep "$COOL"; }

for round in $(seq 1 $ROUNDS); do
  for n in 2 4; do
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers $n > /dev/null 2>&1 & pid=$!
    measure "r$round --workers $n"; stop
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --threads $n > /dev/null 2>&1 & pid=$!
    measure "r$round --threads $n"; stop
    if [ -x .venv/bin/granian ]; then
      ( cd apps/django_wsgi && exec ../../.venv/bin/granian --interface wsgi \
          --workers 1 --blocking-threads $n --host 127.0.0.1 --port 8080 \
          --log-level warning djangoproj.wsgi:application ) > /dev/null 2>&1 & pid=$!
      measure "r$round granian bt=$n"; stop
    fi
  done
done
echo "results in $OUT"
