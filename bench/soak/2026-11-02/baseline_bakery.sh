#!/bin/bash
# bench/soak/2026-10-09/baseline_bakery.sh, unchanged except: the tree is
# named rather than found from the script's path, the port is checked free
# first, and the gunicorn master is stopped by its recorded PID and waited for.
set -x
TREE=/Users/williamtalcott/projects/mojo-http-fdfit
PORT=8313
unset DATABASE_URL DJANGO_SETTINGS_MODULE
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy"; exit 1; fi
cd /tmp/soak/bakerydemo
PATH=/tmp/soak/bakerydemo/.venv/bin:$PATH gunicorn bakerydemo.wsgi -w 2 -b 127.0.0.1:$PORT \
  --log-level warning --timeout 600 > /tmp/soak/bakery-gunicorn.log 2>&1 &
echo $! > /tmp/soak/bakery-gunicorn.pid
sleep 8
curl -s -o /dev/null -w "root=%{http_code}\n" http://127.0.0.1:$PORT/
cd "$TREE"
PATH=/tmp/soak/bakerydemo/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/bakerydemo.json \
  --url http://127.0.0.1:$PORT --baseline /tmp/soak/bakerydemo-gunicorn.json 2>&1 | tail -30
PID=$(cat /tmp/soak/bakery-gunicorn.pid)
kill "$PID" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -0 "$PID" 2>/dev/null && echo "gunicorn $PID still alive" || echo "gunicorn $PID stopped"
