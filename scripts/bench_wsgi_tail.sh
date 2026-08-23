#!/bin/bash
# The keep-alive TAIL, under wrk — the measurement that gates Stage B.
#
# The 2026-08-22 `ab` row (docs/WSGI_PERFORMANCE.md) put threads at throughput
# parity with prefork but did NOT reproduce the 84 ms keep-alive p99 the
# 2026-08-18 `wrk` run saw at two workers, and said so: "this run did not
# excite the tail, not that the tail is gone". `ab` cannot settle it, because
# `ab` is the tool that failed to provoke it. This script is the wrk twin —
# same app, same browser-shaped request, same alternating rounds — and its
# only job is to answer one question: does a keep-alive connection pinned to
# its loop still produce a tail, and do threads change it?
#
# If the tail reappears and threads do not fix it, Stage B (the acceptor +
# Python thread pool with deferred responses, ROADMAP.md) is justified. If it
# does not reappear under the tool that first found it, Stage B is not.
#
# Run inside a free-threaded venv (after `uv run poe py314t-try`, with
# MOJO_PYTHON_LIBRARY and PYTHON_GIL=0 exported and bin/m0serve REBUILT
# there — a Mojo binary's @rpath pins it to the venv it was built in). On a
# GIL build the --threads rows refuse to start, by design.
#
# granian is not a dependency of this repo:
#   uv pip install --python .venv/bin/python granian
# into the swapped venv, which the restore discards.
set -u
cd "$(dirname "$0")/.."
OUT=${BENCH_OUT:-/tmp/bench_wsgi_tail.txt}; : > "$OUT"
DUR=${BENCH_DURATION:-10s}
CONNS=${BENCH_CONNS:-16}
THREADS=${BENCH_WRK_THREADS:-2}

# The same twelve-header browser request the ab row used. wrk's default sends
# only Host, which understates header-handling cost ~2.4x.
HDRS=(-H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
      -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept-Encoding: gzip, deflate, br'
      -H 'Cache-Control: max-age=0' -H 'Upgrade-Insecure-Requests: 1'
      -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' -H 'Referer: http://127.0.0.1:8080/')

rss_tree() { local total=0; for q in $1 $(pgrep -P $1); do r=$(ps -o rss= -p $q 2>/dev/null | tr -d ' '); total=$((total + ${r:-0})); done; echo $total; }

# wrk prints latency as "1.02ms" / "84.21ms" / "1.05s" / "250.00us".
field() { echo "$1" | awk -v pat="$2" '$0 ~ pat {print $2; exit}'; }

measure() {
  local name=$1
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o /dev/null http://127.0.0.1:8080/ \
    || { echo "$name: never healthy" | tee -a "$OUT"; return; }
  wrk -t$THREADS -c$CONNS -d3s "${HDRS[@]}" http://127.0.0.1:8080/ > /dev/null 2>&1  # warmup
  # Keep-alive is wrk's default: connections are held open for the run.
  local ka=$(wrk -t$THREADS -c$CONNS -d$DUR --latency "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  # Connection: close makes every request a fresh connection.
  local cl=$(wrk -t$THREADS -c$CONNS -d$DUR --latency -H 'Connection: close' "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  local rss=$(rss_tree $pid)
  printf '%-26s KA rps %9s p50 %8s p99 %8s max %8s | CLOSE rps %9s p50 %8s p99 %8s | rss %6s KB\n' \
    "$name" \
    "$(echo "$ka" | awk '/Requests\/sec/ {print $2}')" "$(field "$ka" '^ +50%')" "$(field "$ka" '^ +99%')" \
    "$(echo "$ka" | awk '/Latency /{print $4}')" \
    "$(echo "$cl" | awk '/Requests\/sec/ {print $2}')" "$(field "$cl" '^ +50%')" "$(field "$cl" '^ +99%')" \
    "$rss" | tee -a "$OUT"
}

stop() { kill -TERM $pid 2>/dev/null; for q in $(pgrep -P $pid 2>/dev/null); do kill -TERM $q 2>/dev/null; done; wait $pid 2>/dev/null; sleep 1; }

for round in 1 2; do
  for n in 2 4; do
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers $n > /dev/null 2>&1 & pid=$!
    measure "r$round m0serve --workers $n"; stop
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --threads $n > /dev/null 2>&1 & pid=$!
    measure "r$round m0serve --threads $n"; stop
    if [ -x .venv/bin/granian ]; then
      # One process, N blocking threads: Granian's own answer to the same
      # question this repo's --threads asks, on the same interpreter.
      ( cd apps/django_wsgi && exec ../../.venv/bin/granian --interface wsgi \
          --workers 1 --blocking-threads $n --host 127.0.0.1 --port 8080 \
          --log-level warning djangoproj.wsgi:application ) > /dev/null 2>&1 & pid=$!
      measure "r$round granian bt=$n"; stop
    fi
    if [ -x .venv/bin/gunicorn ]; then
      ( cd apps/django_wsgi && exec ../../.venv/bin/gunicorn djangoproj.wsgi:application \
          -w $n -b 127.0.0.1:8080 --log-level warning ) > /dev/null 2>&1 & pid=$!
      measure "r$round gunicorn -w $n"; stop
    fi
  done
done
echo "results in $OUT"
