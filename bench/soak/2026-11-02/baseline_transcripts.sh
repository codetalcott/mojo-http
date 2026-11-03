#!/bin/bash
# bench/soak/2026-10-09/baseline_transcripts.sh, unchanged except: the tree is
# named rather than found from the script's path, the port is checked free
# first, and the gunicorn master is stopped by its recorded PID and waited for.
set -x
TREE=/Users/williamtalcott/projects/mojo-http-fdfit
PORT=8411
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy"; exit 1; fi
cd /tmp/soak/transcripts
PYTHONPATH=/tmp/soak/transcripts/src PATH=/tmp/soak/transcripts/.venv/bin:$PATH \
  gunicorn transcript_manager.wsgi -w 2 -b 127.0.0.1:$PORT --log-level warning --timeout 600 \
  > /tmp/soak/tr-gunicorn.log 2>&1 &
echo $! > /tmp/soak/tr-gunicorn.pid
sleep 6
curl -s -o /dev/null -w "root=%{http_code}\n" http://127.0.0.1:$PORT/
curl -s -o /dev/null -w "student=%{http_code}\n" http://127.0.0.1:$PORT/student/1/
cd "$TREE"
PATH=/tmp/soak/transcripts/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/transcripts.json \
  --url http://127.0.0.1:$PORT --baseline /tmp/soak/transcripts-gunicorn.json 2>&1 | tail -20
PID=$(cat /tmp/soak/tr-gunicorn.pid)
kill "$PID" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -0 "$PID" 2>/dev/null && echo "gunicorn $PID still alive" || echo "gunicorn $PID stopped"
