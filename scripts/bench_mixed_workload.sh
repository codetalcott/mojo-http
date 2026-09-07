#!/bin/bash
# Does a slow view hurt OTHER requests? The measurement that gates Stage B.
#
# docs/WSGI_PERFORMANCE.md's wrk row closed the keep-alive tail question and
# explicitly did NOT close the Stage B question, because its route was
# trivial: a hello-route benchmark has no slow request for a fast one to be
# stuck behind, and slow-view isolation is half of what Stage B buys.
#
# This is that missing measurement. Every loop (worker or thread) runs its
# requests synchronously, and a keep-alive connection stays pinned to the loop
# that accepted it. So with N loops and one slow view in flight, roughly 1/N of
# a client's connections are parked behind it for the whole hold, while the
# other loops stay idle-fast. That is precisely the failure Stage B removes by
# handing requests to a pool instead of to a connection's owning loop.
#
# The shape of the answer:
#   p50 stays ~1ms and p99 climbs toward the slow view's hold time
#     -> connections ARE stranded behind slow work; Stage B is justified
#   p99 barely moves as slow load is added
#     -> N loops already isolate well enough; Stage B stays unbuilt
#
# Stage B is now built (`--blocking-threads N`), so this script is no longer
# a decision but a REGRESSION GATE: the `+bt=N` rows must stay flat under slow
# load the way granian's row does, and the rows without the flag must keep
# showing the degradation — a control that stops failing is a control that
# stopped measuring anything.
#
# Foreground: wrk on `/` (fast). Background: SLOW concurrent requests to
# `/slow?ms=$HOLD`, re-issued for the whole run. Baseline is the same wrk run
# with zero slow requests, so each row is its own control.
set -u
cd "$(dirname "$0")/.."
OUT=${BENCH_OUT:-/tmp/bench_mixed_workload.txt}; : > "$OUT"
DUR=${BENCH_DURATION:-10s}
CONNS=${BENCH_CONNS:-16}
HOLD=${BENCH_HOLD_MS:-200}
# Three rounds is the floor, not a default: the fast-route p99 on a GIL
# build is bimodal (2-3 ms in one fresh server, 7-8 in the next;
# docs/notes/elastic-pool.md), so a two-round median lands on one mode
# and the rendered spread beside it would be a coin toss. The renderer
# refuses to render a mixed-workload artifact with fewer.
ROUNDS=${BENCH_ROUNDS:-3}
COOL=${BENCH_COOLDOWN:-5}

HDRS=(-H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
      -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept-Encoding: gzip, deflate, br'
      -H 'Cache-Control: max-age=0' -H 'Upgrade-Insecure-Requests: 1'
      -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' -H 'Referer: http://127.0.0.1:8080/')

field() { echo "$1" | awk -v pat="$2" '$0 ~ pat {print $2; exit}'; }

# A quiet-machine gate, the CPU twin of the TIME_WAIT gate: refuse to
# record while any process outside this benchmark's own process tree is
# above half a core across three samples a second apart (WindowServer
# idles at 5-30% of one on an active display; the contamination this
# guards against was a core and a half). Contamination
# that depressed the pool rows 7% while the comparators moved 2% was three
# system daemons at a core and a half (docs/notes/elastic-pool.md); a run
# that starts under it is a run that will be discarded, so it does not
# start. Checked before the first row and at the top of every round,
# because a daemon that wakes mid-run contaminates every row after it.
quiet_or_die() {
  python3 "$(dirname "$0")/bench_guard.py" wait --threshold 50 --samples 3 --timeout 120 2>&1 | tee -a "$OUT"
  # `tee` hides the guard's status; PIPESTATUS carries it.
  [ "${PIPESTATUS[0]}" -eq 0 ] \
    || { echo "refusing to record on a busy machine (see above); no artifact is written" | tee -a "$OUT"; exit 1; }
}

slow_pids=""
start_slow() {   # $1 = how many concurrent slow requests to keep in flight
  slow_pids=""
  # NOT `for i in $(seq 1 "$1")`: BSD seq prints "1 0" for `seq 1 0`, so the
  # zero case started TWO loops and the baseline row silently carried the same
  # slow load as the loaded rows — every row looked identical, which is what
  # a broken control looks like rather than a null result.
  [ "$1" -lt 1 ] && return
  local i=0
  while [ "$i" -lt "$1" ]; do
    i=$((i + 1))
    ( while :; do curl -s -o /dev/null --max-time 30 \
        "http://127.0.0.1:8080/slow?ms=$HOLD" || sleep 0.1; done ) &
    slow_pids="$slow_pids $!"
  done
  [ -n "$slow_pids" ] && sleep 1   # let them get established before timing
}
stop_slow() {
  [ -n "$slow_pids" ] || return
  for q in $slow_pids; do
    kill "$q" 2>/dev/null
    for g in $(pgrep -P "$q" 2>/dev/null); do kill "$g" 2>/dev/null; done
  done
  wait $slow_pids 2>/dev/null
  slow_pids=""
}

measure() {   # $1 = label, $2 = concurrent slow requests
  curl --retry 30 --retry-delay 1 --retry-all-errors -s --fail -o /dev/null http://127.0.0.1:8080/ \
    || { echo "$1: never healthy" | tee -a "$OUT"; return; }
  # Warm every worker, THEN settle. Each worker imports Django lazily on its
  # first request, and a 200-400ms import landing inside the measured window
  # is indistinguishable from a slow-view tail — which is exactly the
  # confusion an earlier version of this script produced.
  wrk -t2 -c$CONNS -d5s "${HDRS[@]}" http://127.0.0.1:8080/ > /dev/null 2>&1
  sleep 3
  start_slow "$2"
  local ka=$(wrk -t2 -c$CONNS -d$DUR --latency "${HDRS[@]}" http://127.0.0.1:8080/ 2>&1)
  stop_slow
  local errs=$(echo "$ka" | awk '/Socket errors/ {$1="";$2=""; print; exit}')
  case "$errs" in *connect\ [1-9]*) errs="$errs  <-- MEASUREMENT FAILED (ports)";; esac
  printf '%-30s slow=%d  fast rps %9s p50 %8s p90 %8s p99 %8s max %8s %s\n' \
    "$1" "$2" \
    "$(echo "$ka" | awk '/Requests\/sec/ {print $2}')" \
    "$(field "$ka" '^ +50%')" "$(field "$ka" '^ +90%')" "$(field "$ka" '^ +99%')" \
    "$(echo "$ka" | awk '/Latency /{print $4}')" "${errs:-}" | tee -a "$OUT"
}

stop() { stop_slow; kill -TERM $pid 2>/dev/null; for q in $(pgrep -P $pid 2>/dev/null); do kill -TERM $q 2>/dev/null; done; wait $pid 2>/dev/null; sleep "$COOL"; }
trap 'stop_slow' EXIT

echo "hold=${HOLD}ms  connections=$CONNS  duration=$DUR" | tee -a "$OUT"
[ "$ROUNDS" -ge 3 ] || echo "WARN: BENCH_ROUNDS=$ROUNDS is under the renderer's floor of 3; the artifact will be recorded and then refused by render_bench_docs --check" | tee -a "$OUT"

# All three slow levels run against ONE warm server per configuration. The
# baseline (slow=0) is then the same process, warmed the same way, seconds
# before the loaded rows — so the difference between rows is the slow load and
# nothing else. Restarting per row gave every row its own startup transient
# and made the baseline look as bad as the loaded rows.
sweep() {   # $1 = label
  local slow
  for slow in 0 1 2; do
    measure "$1" "$slow"
  done
  # A respawn is a 200ms+ hole that reads exactly like a slow-view tail.
  if grep -q 'crashed\|respawned' "$SRVLOG" 2>/dev/null; then
    echo "  ^ WARNING: supervisor logged a crash/respawn during the rows above" | tee -a "$OUT"
  fi
}

GRANIAN=$(cd "${BENCH_VENV:-.venv}/bin" && pwd)/granian
SRVLOG=$(mktemp)
quiet_or_die
for round in $(seq 1 $ROUNDS); do
  quiet_or_die
  for n in 4; do
    : > "$SRVLOG"
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers $n > "$SRVLOG" 2>&1 & pid=$!
    sweep "r$round --workers $n"; stop
    : > "$SRVLOG"
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --threads $n > "$SRVLOG" 2>&1 & pid=$!
    sweep "r$round --threads $n"; stop
    # The same two configurations with a handler pool behind each loop. Same
    # loop count, same machine, same minute: the flag is the only variable, so
    # the pair of rows is the measurement.
    : > "$SRVLOG"
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers $n --blocking-threads $n > "$SRVLOG" 2>&1 & pid=$!
    sweep "r$round --workers $n +bt=$n"; stop
    : > "$SRVLOG"
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --threads $n --blocking-threads $n > "$SRVLOG" 2>&1 & pid=$!
    sweep "r$round --threads $n +bt=$n"; stop
    # Granian's shape exactly: ONE worker with a pool of $n. The rows above
    # are $n loops with a pool of $n each; Granian's row below is one worker,
    # so the comparison across the table was four processes against one
    # until 2026-09-07 (docs/notes/pool-tail.md). This row and the next are
    # the same shape, same machine, same minute.
    : > "$SRVLOG"
    bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers 1 --blocking-threads $n > "$SRVLOG" 2>&1 & pid=$!
    sweep "r$round --workers 1 +bt=$n"; stop
    if [ -x ${BENCH_VENV:-.venv}/bin/granian ]; then
      : > "$SRVLOG"
      ( cd apps/django_wsgi && exec "${GRANIAN}" --interface wsgi --workers 1 \
          --blocking-threads $n --host 127.0.0.1 --port 8080 --log-level warning \
          djangoproj.wsgi:application ) > "$SRVLOG" 2>&1 & pid=$!
      sweep "r$round granian bt=$n"; stop
    fi
  done
done
rm -f "$SRVLOG"
echo "results in $OUT"

# Dated, environment-stamped artifact — see scripts/bench_record.py for why
# terminal transcripts are not a record.
# --meta, so the artifact says what it measured. Without it the rendered
# provenance line can only name the environment, and the hold time is the
# one parameter the isolation claim actually depends on: "p99 stays flat"
# means nothing without "flat against a 200ms hold".
python3 "$(dirname "$0")/bench_record.py" mixed_workload "$OUT" \
  --meta "hold_ms=$HOLD" --meta "connections=$CONNS" \
  --meta "duration=$DUR" --meta "rounds=$ROUNDS" \
  || echo "WARN: could not write the bench artifact (see above)"
