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

bin/server --host 127.0.0.1 --port "$PORT" >smoke.log 2>&1 &
PID=$!

ready=""
for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || fail "the server exited: $(cat smoke.log)"
    if curl -sf --max-time 2 "$BASE/health" >/dev/null; then ready=1; break; fi
    sleep 0.1
done
[ -n "$ready" ] || fail "no /health within 5 s"

# The document holds the form and the board, and opens the stream.
curl -s --max-time 5 "$BASE/" >smoke.body
grep -q '<section id="board"' smoke.body || fail "GET / does not hold the board"
grep -q '/events' smoke.body || fail "GET / does not open the stream"

# Two tabs: two streams open at once. A stream never ends, so --max-time IS
# the read, and curl's exit 28 is the expected one.
curl -sN --max-time 4 "$BASE/events" >smoke.one &
ONE=$!
curl -sN --max-time 4 "$BASE/events" >smoke.two &
TWO=$!
sleep 1

code=$(curl -s --max-time 5 -o smoke.body -w '%{http_code}' \
    -d 'text=hello from smoke' "$BASE/messages")
[ "$code" = 200 ] || fail "POST /messages answered $code"
wait "$ONE" "$TWO"
grep -q 'hello from smoke' smoke.one || fail "the first stream did not receive the message"
grep -q 'hello from smoke' smoke.two || fail "the second stream did not receive the message"

# An empty message is refused, and the board does not change.
code=$(curl -s --max-time 5 -o smoke.body -w '%{http_code}' -d 'text=' "$BASE/messages")
[ "$code" = 422 ] || fail "an empty message answered $code, not 422"

kill "$PID"
wait "$PID" 2>/dev/null
rm -f smoke.log smoke.body smoke.one smoke.two
echo "smoke: ok ($BASE)"
