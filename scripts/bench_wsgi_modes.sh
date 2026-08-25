#!/bin/bash
# Prefork vs threads vs gunicorn on ONE interpreter — the threaded mode's
# benchmark row in docs/WSGI_PERFORMANCE.md. Run inside a free-threaded venv
# (after `uv run poe py314t-try`, with MOJO_PYTHON_LIBRARY and PYTHON_GIL=0
# exported and bin/m0serve rebuilt there) — on a GIL build the --threads rows
# refuse to start, by design. gunicorn is not a dependency of this repo:
# `uv pip install --python .venv/bin/python gunicorn` into the swapped venv,
# which the restore discards.
#
# ApacheBench rather than wrk, because ab ships with macOS and wrk does not;
# the table is ratios within one session, and both tools give those.
set -u
cd "$(dirname "$0")/.."
OUT=${BENCH_OUT:-/tmp/bench_wsgi_modes.txt}; : > "$OUT"
N=${BENCH_REQUESTS:-20000}
# A browser-shaped request: twelve headers. wrk's default sends only Host,
# which understates the header-handling cost ~2.4x (WSGI_PERFORMANCE.md).
HDRS=(-H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
      -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept-Encoding: gzip, deflate, br'
      -H 'Cache-Control: max-age=0' -H 'Upgrade-Insecure-Requests: 1'
      -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' -H 'Referer: http://127.0.0.1:8080/')
rss_tree() { local total=0; for q in $1 $(pgrep -P $1); do r=$(ps -o rss= -p $q 2>/dev/null | tr -d ' '); total=$((total + ${r:-0})); done; echo $total; }
measure() {
  local name=$1
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o /dev/null http://127.0.0.1:8080/ || { echo "$name: never healthy" | tee -a "$OUT"; return; }
  ab -q -k -c16 -n3000 "${HDRS[@]}" http://127.0.0.1:8080/ > /dev/null 2>&1   # warmup
  local ka=$(ab -q -k -c16 -n$N "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  local cl=$(ab -q -c16 -n$N "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  local rss=$(rss_tree $pid)
  printf '%-22s keepalive %8s rps p50 %3s p99 %3s ms | close %8s rps p50 %3s p99 %3s ms | failed %s/%s | rss %6s KB\n' "$name" \
    "$(echo "$ka" | awk '/Requests per second/ {print $4}')" "$(echo "$ka" | awk '/ 50%/ {print $2}')" "$(echo "$ka" | awk '/ 99%/ {print $2}')" \
    "$(echo "$cl" | awk '/Requests per second/ {print $4}')" "$(echo "$cl" | awk '/ 50%/ {print $2}')" "$(echo "$cl" | awk '/ 99%/ {print $2}')" \
    "$(echo "$ka" | awk '/Failed requests/ {print $3}')" "$(echo "$cl" | awk '/Failed requests/ {print $3}')" "$rss" | tee -a "$OUT"
}
stop() { kill -TERM $pid 2>/dev/null; for q in $(pgrep -P $pid 2>/dev/null); do kill -TERM $q 2>/dev/null; done; wait $pid 2>/dev/null; sleep 1; }
# Alternating rounds: the ratio within a round is the result, not the absolutes.
for round in 1 2; do
  for n in 2 4; do
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers $n > /dev/null 2>&1 & pid=$!
    measure "r$round m0serve --workers $n"; stop
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --threads $n > /dev/null 2>&1 & pid=$!
    measure "r$round m0serve --threads $n"; stop
    if [ -x .venv/bin/gunicorn ]; then
      ( cd apps/django_wsgi && exec ../../.venv/bin/gunicorn djangoproj.wsgi:application -w $n -b 127.0.0.1:8080 --log-level warning ) > /dev/null 2>&1 & pid=$!
      measure "r$round gunicorn -w $n"; stop
    fi
  done
done
echo "results in $OUT"

# Dated, environment-stamped artifact — see scripts/bench_record.py for why
# terminal transcripts are not a record.
python3 "$(dirname "$0")/bench_record.py" wsgi_modes "$OUT" \
  || echo "WARN: could not write the bench artifact (see above)"
