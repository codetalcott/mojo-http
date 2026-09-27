#!/bin/sh
# Build, serve on a port of this run's own, sign in, probe the wire, stop by pid.
#
#     ./smoke.sh [PORT]
#
# The four habits a probe of a running server needs, written down once:
# a port nothing else is using, a wait for readiness before the first
# probe, a stop by PID (never by name: another server may be running), and
# an exit status that is the probe's, not the last command's.
#
# The server runs with a key and a password of this run's own, whatever
# the shell exported, so the run never signs in to a real deployment's
# configuration and never needs one.
set -u

PORT="${1:-$((20000 + $$ % 20000))}"
BASE="http://127.0.0.1:$PORT"
PID=""
JAR=smoke.jar
APP_KEY="smoke-$$-0123456789abcdef0123456789abcdef"
APP_PASSWORD="smoke-$$"
export APP_KEY APP_PASSWORD
unset APP_USER APP_TTL APP_SECURE APP_KEY_PREV

fail() {
    echo "smoke: FAIL: $1" >&2
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    exit 1
}

uv run m0 build || fail "m0 build"

# Without its password the server refuses to start, naming the variable --
# under `--doctor` too, which starts nothing either way.
out=$(env -u APP_PASSWORD bin/server --doctor 2>&1)
[ $? = 78 ] || fail "without APP_PASSWORD the server did not exit 78: $out"
echo "$out" | grep -q APP_PASSWORD || fail "the refusal does not name APP_PASSWORD: $out"

bin/server --port "$PORT" >smoke.log 2>&1 &
PID=$!

ready=""
for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || fail "the server exited: $(cat smoke.log)"
    if curl -sf --max-time 2 "$BASE/health" >/dev/null; then ready=1; break; fi
    sleep 0.1
done
[ -n "$ready" ] || fail "no /health within 5 s"

# Signed out: a navigation goes to the login page, a swap gets the form.
got=$(curl -s --max-time 5 -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/items")
[ "$got" = "303 $BASE/login" ] || fail "a signed-out GET /items answered $got"
code=$(curl -s --max-time 5 -o smoke.body -w '%{http_code}' \
    -H 'HX-Request-Type: partial' "$BASE/items")
[ "$code" = 401 ] || fail "a signed-out swap answered $code, not 401"
grep -q 'action="/login"' smoke.body || fail "the 401 does not carry the login form"

# The wrong password is a 401; the right one a 303 to the list, with the cookie.
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
    --data-urlencode 'user=admin' --data-urlencode 'password=wrong' "$BASE/login")
[ "$code" = 401 ] || fail "the wrong password answered $code, not 401"
rm -f "$JAR"
got=$(curl -s --max-time 5 -o /dev/null -c "$JAR" -w '%{http_code} %{redirect_url}' \
    --data-urlencode 'user=admin' --data-urlencode "password=$APP_PASSWORD" "$BASE/login")
[ "$got" = "303 $BASE/items" ] || fail "signing in answered $got"

# Signed in: the document, and the token every write carries.
curl -s --max-time 5 -b "$JAR" "$BASE/items" >smoke.body
grep -q '<!doctype html>' smoke.body || fail "GET /items signed in is not a document"
TOKEN=$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' smoke.body | head -n 1)
[ -n "$TOKEN" ] || fail "the list carries no CSRF token"

# A write without the token is a 403; with it, the list.
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -b "$JAR" \
    -H 'HX-Request-Type: partial' -d 'title=milk' "$BASE/items")
[ "$code" = 403 ] || fail "POST /items without the token answered $code, not 403"
curl -s --max-time 5 -b "$JAR" -H 'HX-Request-Type: partial' \
    --data-urlencode 'title=milk' --data-urlencode "csrf=$TOKEN" "$BASE/items" \
    | grep -q 'milk' || fail "POST /items did not answer the list"

# Delete: the token in the URL is never read; in the header it is.
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X DELETE -b "$JAR" \
    -H 'HX-Request-Type: partial' "$BASE/items/1?csrf=$TOKEN")
[ "$code" = 403 ] || fail "a DELETE with the token in its URL answered $code, not 403"
code=$(curl -s --max-time 5 -o smoke.body -w '%{http_code}' -X DELETE -b "$JAR" \
    -H 'HX-Request-Type: partial' -H "X-CSRF-Token: $TOKEN" "$BASE/items/1")
[ "$code" = 200 ] || fail "DELETE /items/1 answered $code"
grep -q 'milk' smoke.body && fail "DELETE /items/1 left the item in the list"

# Signing out expires the cookie: the list is the login page's again.
got=$(curl -s --max-time 5 -o /dev/null -b "$JAR" -c "$JAR" -w '%{http_code} %{redirect_url}' \
    --data-urlencode "csrf=$TOKEN" "$BASE/logout")
[ "$got" = "303 $BASE/login" ] || fail "signing out answered $got"
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -b "$JAR" "$BASE/items")
[ "$code" = 303 ] || fail "after signing out GET /items answered $code, not 303"

kill "$PID"
wait "$PID" 2>/dev/null
rm -f smoke.log smoke.body "$JAR"
echo "smoke: ok ($BASE)"
