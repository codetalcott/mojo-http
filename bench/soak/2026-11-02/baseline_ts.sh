#!/bin/bash
# bench/soak/2026-10-09/baseline_ts.sh, unchanged except: the tree is named
# rather than found from the script's path, the port is checked free first,
# and daphne is stopped by its recorded PID and waited for.
set -x
TREE=/Users/williamtalcott/projects/mojo-http-fdfit
PORT=8401
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy"; exit 1; fi
cd /tmp/soak/textshelf
export DATABASE_URL="postgres://postgres@localhost:5432/textshelf_soak"
export DJANGO_SETTINGS_MODULE=config.settings.local
PATH=/tmp/soak/textshelf/.venv/bin:$PATH daphne -b 127.0.0.1 -p $PORT config.asgi:application \
  > /tmp/soak/ts-daphne.log 2>&1 &
echo $! > /tmp/soak/ts-daphne.pid
sleep 8
curl -s -o /dev/null -w "root=%{http_code}\n" http://127.0.0.1:$PORT/
curl -s -o /dev/null -w "login=%{http_code}\n" http://127.0.0.1:$PORT/accounts/login/
cd "$TREE"
PATH=/tmp/soak/textshelf/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/textshelf.json \
  --url http://127.0.0.1:$PORT --baseline /tmp/soak/textshelf-daphne.json 2>&1 | tail -25
PID=$(cat /tmp/soak/ts-daphne.pid)
kill "$PID" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -0 "$PID" 2>/dev/null && echo "daphne $PID still alive" || echo "daphne $PID stopped"
