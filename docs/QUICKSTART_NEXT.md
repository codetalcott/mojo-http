# After the quickstart

This page continues the [quickstart](../QUICKSTART.md) in its directory,
with `realtime.py` from step 2 and the virtualenv from step 1. Stop the
server from step 3 first. CI runs these blocks after the quickstart's, in
the same scratch directory.

## 1. Two workers

Stop the server (Ctrl-C) and restart it with two workers. A publish from a
view on either worker reaches subscribers on both: the bus and the id
counter are created before the fork. Ids belong to the server's lifetime; a
fresh server numbers from 1 again, so `Last-Event-ID` replay is scoped to a
running server.

```bash serve
m0serve realtime:application --realtime --workers 2 --health-path /health --port 8000
```

```bash verify
curl -sf --retry 20 --retry-delay 1 --retry-all-errors http://127.0.0.1:8000/health > /dev/null

curl -sN --max-time 6 "http://127.0.0.1:8000/events?channel=news" > stream2.txt &
sleep 1

RESPONSE=$(curl -s -X POST -d channel=news -d msg="hello every worker" http://127.0.0.1:8000/publish)
echo "$RESPONSE"
echo "$RESPONSE" | grep -q '"workers": 2'

for i in $(seq 1 25); do
  grep -q "data: hello every worker" stream2.txt 2>/dev/null && break
  sleep 0.2
done
grep "data: hello every worker" stream2.txt

SECOND_ID=$(grep -oE "^id: [0-9]+" stream2.txt | head -1 | cut -d' ' -f2)
test -n "$SECOND_ID"
echo "publish reached 2 workers; delivered (event id $SECOND_ID)"

# "No second process" is a checkable claim, so check it: the whole server is
# a supervisor and its two workers, every one of them the m0serve binary.
# And the wheel required nothing else to be installed beside it.
test "$(pgrep -x m0serve | wc -l | tr -d ' ')" -eq 3
pip show m0serve | grep -E '^Requires:\s*$'
echo "one process tree, no dependencies"
```

The publish's response says the frame reached both workers, and a
subscriber received it. Which worker that subscriber landed on is the
kernel's choice; the repository's `smoke-django-realtime` pins one
subscriber on each worker and asserts the far one hears it.

## 2. The same views in Flask

The server reads two response headers and a `publish()` call, which any
WSGI framework can produce. Here is the same application in Flask. One line
is Flask-specific: `websocket=True` on the socket route, which Werkzeug's
router requires before it will match an upgrade request.

```bash setup
pip install --quiet flask
cat > realtime_flask.py <<'PY'
"""The quickstart's four views, in Flask, served by m0serve."""
from flask import Flask, Response, jsonify, request

from m0serve import m0pub

app = Flask(__name__)


@app.get("/events")
def events():
    # Same two headers, same meaning: m0serve holds the connection and
    # subscribes it; Flask's part ends when the view returns.
    response = Response(": connected\n\n", mimetype="text/event-stream")
    response.headers["M0-Hold"] = "stream"
    response.headers["M0-Channel"] = request.args.get("channel", "news")
    return response


@app.route("/ws", websocket=True)
def ws():
    # The one Flask-specific line. Werkzeug's router refuses to match an
    # upgrade request (`Connection: Upgrade`, `Upgrade: websocket`) to an
    # ordinary HTTP rule -- it answers 400 before any view runs -- so the
    # rule that approves a socket must say so. Django has no such check.
    response = Response("")
    response.headers["M0-Hold"] = "websocket"
    response.headers["M0-Channel"] = request.args.get("channel", "news")
    return response


@app.post("/ws/message")
def ws_message():
    # Flask has no CSRF middleware to exempt; the path is reserved by the
    # server either way, so only the synthesised POST reaches this view.
    channel = request.headers.get("M0-Channel", "news")
    m0pub.publish(channel, request.get_data(as_text=True))
    return jsonify(ok=True)


@app.post("/publish")
def publish():
    workers, event_id = m0pub.publish_with_id(
        request.form.get("channel", "news"), request.form.get("msg", "")
    )
    return jsonify(workers=workers, id=event_id)
PY
```

Serve it with two workers, as the Django file was:

```bash serve
m0serve realtime_flask:app --realtime --workers 2 --health-path /health --port 8000
```

The checks are the two-worker ones above, plus the WebSocket handshake: a
view that answered `M0-Hold: websocket` gets the RFC 6455 upgrade, and
`curl` shows the 101.

```bash verify
curl -sf --retry 20 --retry-delay 1 --retry-all-errors http://127.0.0.1:8000/health > /dev/null

curl -sN --max-time 6 "http://127.0.0.1:8000/events?channel=news" > flask.txt &
sleep 1

RESPONSE=$(curl -s -X POST -d channel=news -d msg="hello from flask" http://127.0.0.1:8000/publish)
echo "$RESPONSE"
echo "$RESPONSE" | grep -Eq '"workers": ?2'

for i in $(seq 1 25); do
  grep -q "data: hello from flask" flask.txt 2>/dev/null && break
  sleep 0.2
done
grep "data: hello from flask" flask.txt

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "http://127.0.0.1:8000/ws?channel=news" || true)
test "$code" = "101"
echo "Flask: SSE delivered across 2 workers, WebSocket upgraded ($code)"
```

```text
{"id":1,"workers":2}
data: hello from flask
Flask: SSE delivered across 2 workers, WebSocket upgraded (101)
```

CI extracts this file from this page and drives it with a raw RFC 6455
probe, one socket pinned on each worker (`poe smoke-flask-realtime`).

## 3. Under gunicorn

Stop m0serve and serve the Django file with gunicorn. The `M0-` headers mean
nothing to it: the hold views answer as short plain responses, the upgrade
request gets an ordinary 200, and `publish()` reports zero workers without
raising.

```bash setup
pip install --quiet gunicorn
```

```bash serve
gunicorn --bind 127.0.0.1:8000 realtime:application
```

```bash verify
curl -sf --retry 20 --retry-delay 1 --retry-all-errors http://127.0.0.1:8000/ > /dev/null

# Under m0serve this connection is held open; here it must finish inside
# the deadline with the body the view wrote, or curl exits 28 and so does
# this block.
curl -si --max-time 5 "http://127.0.0.1:8000/events?channel=news" > degraded.txt
grep -q '^HTTP/1.1 200' degraded.txt
grep -q '^: connected' degraded.txt

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "http://127.0.0.1:8000/ws?channel=news")
test "$code" = "200"

curl -s -X POST -d channel=news -d msg="nobody is held" http://127.0.0.1:8000/publish | grep -q '"workers": 0'
echo "under gunicorn: /events answered $(grep -c '' degraded.txt) lines and closed, /ws answered $code, publish reached 0 workers"
```

## 4. A stream the server holds against a grant

The hold views above run in Python, once per connection, and that is
cheap. A `--mount PREFIX=hold` moves even that off the interpreter: your
view still decides, with its session and its database, whether this
browser may hold a stream and on which channel, but instead of holding it
signs the decision into the stream URL, and a Mojo pool thread verifies
the signature and holds. The key is one environment variable both sides
read. `granted.py` is a plain WSGI application with the two views a real
one has — one that issues a grant, one that publishes.

```bash setup
export M0_GRANT_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
cat > granted.py <<'PY'
import json
from urllib.parse import parse_qs
from http.cookies import SimpleCookie

from m0serve import grant, m0pub


def application(environ, start_response):
    path = environ["PATH_INFO"]
    query = parse_qs(environ["QUERY_STRING"])
    channel = query.get("channel", ["news"])[0]
    if path == "/grant":
        # Your authorization runs here, with everything the request
        # carries. The grant is bound to the session cookie, so the URL is
        # useless to anyone who copies it without the cookie.
        cookies = SimpleCookie(environ.get("HTTP_COOKIE", ""))
        session = cookies["sessionid"].value if "sessionid" in cookies else None
        if session is None:
            start_response("401 Unauthorized", [("Content-Type", "application/json")])
            return [b'{"error":"sign in first"}']
        url = grant.stream_url("/rt", channel, session=session, ttl=3600)
        start_response("200 OK", [("Content-Type", "application/json")])
        return [json.dumps({"url": url}).encode()]
    if path == "/publish":
        msg = query.get("msg", [""])[0]
        workers, event_id = m0pub.publish_with_id(channel, msg, event="message")
        start_response("200 OK", [("Content-Type", "application/json")])
        return [json.dumps({"id": event_id}).encode()]
    start_response("404 Not Found", [("Content-Type", "text/plain")])
    return [b"not found\n"]
PY
```

Serve it with the hold mount beside it. The mount needs `--realtime`, which
is what wires a pool thread's hold to the event loop, and refuses to start
without the key.

```bash serve
m0serve --mount /=granted:application --mount /rt=hold --realtime --health-path /health --port 8000
```

Ask for a grant as a signed-in browser would, open the URL it returns with
the same cookie, and publish. Then try the URL without the cookie.

```bash verify
curl --retry 20 --retry-delay 1 --retry-all-errors --silent --fail http://localhost:8000/health
URL=$(curl -s -H 'Cookie: sessionid=demo-session' 'http://localhost:8000/grant?channel=news' \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])')
echo "$URL"
curl -sN --max-time 6 -H 'Cookie: sessionid=demo-session' "http://localhost:8000$URL" > granted-stream.txt &
sleep 1
curl -s -X POST 'http://localhost:8000/publish?channel=news&msg=hello%20from%20python'
for i in $(seq 1 25); do
  grep -q "data: hello from python" granted-stream.txt 2>/dev/null && break
  sleep 0.2
done
cat granted-stream.txt
grep -q 'data: hello from python' granted-stream.txt
curl -s "http://localhost:8000$URL"
curl -s "http://localhost:8000$URL" | grep -q '"reason":"no session cookie"'
```

```text
/rt/stream?g=v1.3f1c9a2b.1757700000.news.HsHCa1DV08WNlYMYGvgHZg.<43 characters>
{"id": 1}
: open

id: 1
event: message
data: hello from python

{"error":"invalid","reason":"no session cookie"}
```

The grant is `v1.<key id>.<expiry>.<channel>.<session binding>.<signature>`
and the mount checks it in that order — the signature in constant time,
the expiry against its own clock, the cookie against the binding — before
it holds. A refusal is a 401 whose `error` is `expired`, meaning ask for a
fresh URL, or `invalid`, meaning stop. Rotate the key by moving the old
value to `M0_GRANT_KEY_PREV`; grants signed under either verify until you
unset it. What the mount will not do is close a stream your application
later decides against: revocation is bounded by the grant's `ttl`, one
hour by default.
