#!/bin/sh
# Build, serve on a port of this run's own, probe the wire, stop by pid.
#
#     ./smoke.sh [PORT]
#
# The four habits a probe of a running server needs, written down once:
# a port nothing else is using, a wait for readiness before the first
# probe, a stop by PID (never by name: another server may be running), and
# an exit status that is the probe's, not the last command's.
set -u

PORT="${1:-$((20000 + $$ % 20000))}"
BASE="http://127.0.0.1:$PORT"
PID=""

fail() {
    echo "smoke: FAIL: $1" >&2
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    exit 1
}

uv run m0 build || fail "m0 build"

# A database of this run's own, so the restart below proves the count came
# back from the FILE and not from a previous run.
DB="smoke-$$.db"
rm -f "$DB" "$DB-wal" "$DB-shm"

M0_DB="$DB" bin/server --port "$PORT" >smoke.log 2>&1 &
PID=$!

ready=""
for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || fail "the server exited: $(cat smoke.log)"
    if curl -sf --max-time 2 "$BASE/health" >/dev/null; then ready=1; break; fi
    sleep 0.1
done
[ -n "$ready" ] || fail "no /health within 5 s"

# The document holds the fragment and opens the stream.
curl -s --max-time 5 "$BASE/" >smoke.body
grep -q '<section id="live"' smoke.body || fail "GET / does not hold the live fragment"
grep -q '/events' smoke.body || fail "GET / does not open the stream"

# The stream: a stream never ends, so --max-time IS the read, and curl's
# exit 28 is the expected one. Two frames for the fragment's id, differing.
curl -sN --max-time 3 "$BASE/events" >smoke.body
frames=$(grep -c '^event: datastar-patch-elements' smoke.body)
[ "$frames" -ge 2 ] || fail "$frames frame(s) in 3 s, expected at least 2"
distinct=$(grep '^data: elements <section id="live"' smoke.body | sort -u | wc -l)
[ "$distinct" -ge 2 ] || fail "the frames do not differ"

# A kick is counted, and nothing was refused by the bus.
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST "$BASE/kick")
[ "$code" = 204 ] || fail "POST /kick answered $code"
curl -s --max-time 5 "$BASE/stats" >smoke.body
grep -q '"kicks":1,' smoke.body || fail "the kick was not counted: $(cat smoke.body)"
grep -q '"refused":0,' smoke.body || fail "the bus refused a frame: $(cat smoke.body)"

# The kick survives a restart: the kick view counted it in SQLite inside
# its own request, and /stats reads it back from the file.
kill "$PID"
wait "$PID" 2>/dev/null
PID=""
M0_DB="$DB" bin/server --port "$PORT" >smoke.log 2>&1 &
PID=$!
kept=""
for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || fail "the restarted server exited: $(cat smoke.log)"
    if curl -sf --max-time 2 "$BASE/stats" 2>/dev/null | grep -q '"kicks":1,'; then kept=1; break; fi
    sleep 0.1
done
[ -n "$kept" ] || fail "after a restart /stats does not carry the kick: $(curl -s "$BASE/stats")"

kill "$PID"
wait "$PID" 2>/dev/null
rm -f smoke.log smoke.body "$DB" "$DB-wal" "$DB-shm"
echo "smoke: ok ($BASE)"
