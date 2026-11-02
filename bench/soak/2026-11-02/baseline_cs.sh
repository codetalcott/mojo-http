#!/bin/bash
# bench/soak/2026-10-09/baseline_cs.sh, unchanged except: the tree is named
# rather than found from the script's path, each port is checked free first,
# and each reference server is stopped by its recorded PID and waited for.
set -x
TREE=/Users/williamtalcott/projects/mojo-http-fdfit
stop() {
  local pid=$(cat "$1"); kill "$pid" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && echo "$pid still alive" || echo "$pid stopped"
}
for p in 8431 8444; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p busy"; exit 1; fi
done
cd /tmp/soak/color-separation
PATH=/tmp/soak/color-separation/.venv/bin:$PATH gunicorn halftone_studio.wsgi -w 2 -b 127.0.0.1:8431 \
  --log-level warning --timeout 600 > /tmp/soak/cs-gunicorn.log 2>&1 &
echo $! > /tmp/soak/cs-gunicorn.pid
sleep 6
cd "$TREE"
PATH=/tmp/soak/color-separation/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/color-separation.json \
  --url http://127.0.0.1:8431 --baseline /tmp/soak/cs-gunicorn.json 2>&1 | tail -20
stop /tmp/soak/cs-gunicorn.pid
sleep 3
cd /tmp/soak/color-separation
PATH=/tmp/soak/color-separation/.venv/bin:$PATH uvicorn halftone_studio.asgi:application \
  --host 127.0.0.1 --port 8444 --log-level warning > /tmp/soak/cs-uvicorn.log 2>&1 &
echo $! > /tmp/soak/cs-uvicorn.pid
sleep 6
cd "$TREE"
PATH=/tmp/soak/color-separation/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/color-separation.json \
  --url http://127.0.0.1:8444 --baseline /tmp/soak/cs-uvicorn.json 2>&1 | tail -20
stop /tmp/soak/cs-uvicorn.pid
