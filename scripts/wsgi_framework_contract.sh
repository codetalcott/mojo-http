#!/usr/bin/env bash
# The framework-facing half of WSGI conformance, shared by every framework row.
#
#   scripts/wsgi_framework_contract.sh <base-url> <expected-root-body> <label>
#
# `smoke-wsgi` asks whether the bridge implements PEP 3333, against a bare
# callable with no framework to blame. This asks a different question: whether
# a real framework's idioms survive the crossing — its router, its cookie jar,
# its request body parsing, its error handling. Those need a framework, and
# every framework answers them the same way, so the assertions live here once
# instead of once per row.
#
# The route contract a framework row must implement:
#
#   GET  /              the row's own body, passed in as $2
#   GET  /cookies       two Set-Cookie headers (sessionid, csrftoken)
#   GET  /cookies/echo  request cookies as sorted "k=v", joined with "|"
#   POST /echo          the request body, unchanged
#   GET  /binary        all 256 byte values
#   GET  /query?name=   the parsed `name` parameter
#   GET  /boom          raises, so the server's 500 path is reachable
#   (any unrouted path) the framework's own 404
#
# Everything a single framework does differently — Django's sessions, its
# prefork assertions, the RSS guard — stays in that row's own task.

set -u

BASE="${1:?usage: $0 <base-url> <expected-root-body> <label>}"
ROOT_BODY="${2:?missing expected root body}"
LABEL="${3:-framework}"

fail() { echo "[$LABEL contract] $1" >&2; exit 1; }

# Doubles as the readiness probe: the row's task starts the server and calls
# this immediately, so the retry budget lives here rather than in every row.
curl --retry 30 --retry-delay 2 --retry-all-errors --silent --fail "$BASE/" \
  | grep -qF "$ROOT_BODY" || fail "GET / did not return '$ROOT_BODY'"

# Headers is a Dict[String, String] on the Mojo side, so a naive mapping keeps
# only the last Set-Cookie. Every framework sets two on an authenticated
# response — a session cookie and a CSRF token — so this is the shape that
# matters, not a synthetic one.
n=$(curl -s -i "$BASE/cookies" | grep -ci '^set-cookie:')
[ "$n" = "2" ] || fail "expected 2 Set-Cookie headers, got $n"

# The request half. The parser used to divert Cookie out of the header map into
# its own jar, so HTTP_COOKIE never reached the environ and the framework saw
# no cookies at all — every session, login and CSRF check silently inert, with
# nothing logged, because a request that carries no session just looks like a
# logged-out visitor. The value deliberately contains '=': base64 pads with it,
# so a real session id does too, and splitting on every '=' truncates it.
got=$(curl -s -H 'Cookie: sessionid=YWJjZGVm==; csrftoken=a=b=c' "$BASE/cookies/echo")
[ "$got" = 'csrftoken=a=b=c|sessionid=YWJjZGVm==' ] \
  || fail "request cookies did not reach the application: got '$got'"

# ...and a request that sends none must not acquire any.
got=$(curl -s "$BASE/cookies/echo")
[ -z "$got" ] || fail "a cookieless request arrived carrying cookies: '$got'"

# Multiple Cookie fields are one '; '-joined list (RFC 6265 5.4), not last-wins,
# which is what a unique-key header map gives you without the rejoin.
got=$(curl -s -H 'Cookie: a=1' -H 'Cookie: b=2' "$BASE/cookies/echo")
[ "$got" = 'a=1|b=2' ] || fail "split Cookie headers did not rejoin: got '$got'"

# wsgi.input: the request body has to survive the crossing.
echo 'round-trip-me' | curl -s --data-binary @- "$BASE/echo" \
  | grep -q 'round-trip-me' || fail 'POST body did not round-trip'

# A body past the shim's 64KB transfer buffer, so grow() runs.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
python3 -c 'import sys; sys.stdout.buffer.write(b"x" * 262144)' > "$tmp"
n=$(curl -s --data-binary @"$tmp" "$BASE/echo" | wc -c | tr -d ' ')
[ "$n" = "262144" ] || fail "a 256KB body did not round-trip: echoed $n bytes"

# All 256 byte values, unchanged. A latin-1 round trip through a Mojo String
# would corrupt everything above 0x7F, since Mojo strings are UTF-8.
python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256)))' > "$tmp"
curl -s "$BASE/binary" > "$tmp.got"
cmp -s "$tmp" "$tmp.got" \
  || fail "binary body was corrupted in transit ($(wc -c < "$tmp.got") bytes)"
rm -f "$tmp.got"

# QUERY_STRING reaches the framework's own parameter parsing.
curl -s "$BASE/query?name=ada+lovelace" | grep -q 'ada lovelace' \
  || fail 'QUERY_STRING did not reach the view'

# The response mapper carries the framework's status rather than hard-coding
# 200 — here, the framework's own 404 for an unrouted path.
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/no-such-route")
[ "$code" = "404" ] || fail "expected 404 from the framework's router, got $code"

# A view that raises becomes the server's 500 rather than killing the process.
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/boom")
[ "$code" = "500" ] || fail "expected 500 from a raising view, got $code"

# ...and the server is still answering afterwards.
curl -s --fail "$BASE/" > /dev/null || fail 'server died after a view raised'

echo "[$LABEL contract] OK"
