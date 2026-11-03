#!/bin/bash
# The abandon-only route /notifications/stream/ is skipped by --baseline, so
# check it answers a signed-in session from daphne: status, content type,
# and the first bytes within 3 s. One login (the limiter allows 10 / 15 min).
# Browser-like UA + Accept-Language keep BotDetectionMiddleware below its
# fake-200 threshold (see the manifest's comment_headers).
set -u
PORT=8401
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy"; exit 1; fi
cd /tmp/soak/textshelf
export DATABASE_URL="postgres://postgres@localhost:5432/textshelf_soak"
export DJANGO_SETTINGS_MODULE=config.settings.local
PATH=/tmp/soak/textshelf/.venv/bin:$PATH daphne -b 127.0.0.1 -p $PORT config.asgi:application \
  > /tmp/soak/ts-daphne-stream.log 2>&1 &
echo $! > /tmp/soak/ts-daphne.pid
sleep 8
J=/tmp/soak/ts.jar; rm -f $J
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'
H=(-A "$UA" -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept: text/html' -H 'Accept-Encoding: gzip')
tok=$(curl -s "${H[@]}" -c $J -b $J http://127.0.0.1:$PORT/accounts/login/ --compressed | grep -o 'name="csrfmiddlewaretoken" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')
echo "login -> $(curl -s "${H[@]}" -c $J -b $J -H "Referer: http://127.0.0.1:$PORT/accounts/login/" -o /dev/null -w '%{http_code} %{redirect_url}' \
  --data-urlencode "csrfmiddlewaretoken=$tok" --data-urlencode login=soak@example.com --data-urlencode password=soak-pass-123 \
  http://127.0.0.1:$PORT/accounts/login/)"
echo "notifications -> $(curl -s "${H[@]}" -b $J -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/notifications/)"
curl -s -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept: text/event-stream' -b $J -m 3 \
  -D /tmp/soak/ts-stream.head -o /tmp/soak/ts-stream.body http://127.0.0.1:$PORT/notifications/stream/
echo "stream curl exit $? (28 = held open until -m 3)"
head -1 /tmp/soak/ts-stream.head; grep -i '^content-type' /tmp/soak/ts-stream.head
echo "first bytes: $(head -c 120 /tmp/soak/ts-stream.body | tr '\n' '|')"
PID=$(cat /tmp/soak/ts-daphne.pid)
kill "$PID" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -0 "$PID" 2>/dev/null && echo "daphne $PID still alive" || echo "daphne $PID stopped"
rm -f $J
