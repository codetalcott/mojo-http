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

bin/server --port "$PORT" >smoke.log 2>&1 &
PID=$!

ready=""
for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || fail "the server exited: $(cat smoke.log)"
    if curl -sf --max-time 2 "$BASE/health" >/dev/null; then ready=1; break; fi
    sleep 0.1
done
[ -n "$ready" ] || fail "no /health within 5 s"

# A navigation gets a document; an htmx 4 swap gets the bare fragment.
curl -s --max-time 5 "$BASE/items" | grep -q '<!doctype html>' \
    || fail "GET /items is not a document"
curl -s --max-time 5 -H 'HX-Request-Type: partial' "$BASE/items" \
    | grep -q '^<section id="items"' || fail "a partial GET /items is not the bare fragment"

# Create, then an empty title: a 422 that is still the fragment.
curl -s --max-time 5 -H 'HX-Request-Type: partial' -d 'title=milk' "$BASE/items" \
    | grep -q 'milk' || fail "POST /items did not answer the list"
code=$(curl -s --max-time 5 -o smoke.body -w '%{http_code}' \
    -H 'HX-Request-Type: partial' -d 'title=' "$BASE/items")
[ "$code" = 422 ] || fail "an empty title answered $code, not 422"
grep -q 'role="alert"' smoke.body || fail "the 422 carries no alert"

# Delete.
code=$(curl -s --max-time 5 -o smoke.body -w '%{http_code}' -X DELETE \
    -H 'HX-Request-Type: partial' "$BASE/items/1")
[ "$code" = 200 ] || fail "DELETE /items/1 answered $code"
grep -q 'milk' smoke.body && fail "DELETE /items/1 left the item in the list"

kill "$PID"
wait "$PID" 2>/dev/null
rm -f smoke.log smoke.body
echo "smoke: ok ($BASE)"
