#!/bin/bash
cd "$(dirname "$0")/.."
OUT=./out
BIN=$PWD/bin/m0serve
# re-capture color-separation's two references against the rebuilt subject
cd /tmp/soak/color-separation
(PATH=/tmp/soak/color-separation/.venv/bin:$PATH gunicorn halftone_studio.wsgi -w 2 -b 127.0.0.1:8431 --log-level warning --timeout 600 > /tmp/soak/cs-gunicorn-rel.log 2>&1 & echo $! > /tmp/soak/cs-gunicorn.pid); sleep 5
cd "$OLDPWD"; PATH=/tmp/soak/color-separation/.venv/bin:$PATH python3 scripts/soak.py --manifest scripts/soak_manifests/color-separation.json --url http://127.0.0.1:8431 --baseline /tmp/soak/cs-gunicorn.json 2>&1 | grep -E "baseline written|rror"
kill $(cat /tmp/soak/cs-gunicorn.pid) 2>/dev/null; sleep 2
cd /tmp/soak/color-separation
(PATH=/tmp/soak/color-separation/.venv/bin:$PATH uvicorn halftone_studio.asgi:application --host 127.0.0.1 --port 8444 --log-level warning > /tmp/soak/cs-uvicorn-rel.log 2>&1 & echo $! > /tmp/soak/cs-uvicorn.pid); sleep 5
cd "$OLDPWD"; PATH=/tmp/soak/color-separation/.venv/bin:$PATH python3 scripts/soak.py --manifest scripts/soak_manifests/color-separation.json --url http://127.0.0.1:8444 --baseline /tmp/soak/cs-uvicorn.json 2>&1 | grep -E "baseline written|rror"
kill $(cat /tmp/soak/cs-uvicorn.pid) 2>/dev/null; sleep 2
row() {
  local name=$1 venv=$2 port=$3 secs=$4; shift 4
  local args=(); while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  echo "=== $name start $(date +%H:%M:%S)"
  PATH="$venv/.venv/bin:$PATH" python3 scripts/soak.py --manifest "scripts/soak_manifests/${name%%_*}.json" \
    --url "http://127.0.0.1:$port" --seconds "$secs" --log "$OUT/$name.log" "${args[@]}" \
    --serve "$*" > "$OUT/$name.out" 2>&1
  echo "=== $name exit=$? $(date +%H:%M:%S)"; tail -1 "$OUT/$name.out" | cut -c1-160
  sleep 5
}
row color-separation_wsgi_pool8_uploads_churn /tmp/soak/color-separation 8503 120 --capture /tmp/soak/cs-gunicorn.json --churn-every 60 --cwd /tmp/soak/color-separation -- \
  "$BIN" halftone_studio.wsgi --max-body 64m --port 8503 --metrics
row color-separation_asgi_executor /tmp/soak/color-separation 8504 90 --capture /tmp/soak/cs-uvicorn.json --cwd /tmp/soak/color-separation -- \
  "$BIN" halftone_studio.asgi --max-body 64m --port 8504 --metrics
export DATABASE_URL="postgres://postgres:REDACTED@localhost:5432/textshelf_soak" DJANGO_SETTINGS_MODULE=config.settings.local
row textshelf_asgi_executor_churn /tmp/soak/textshelf 8505 180 --capture /tmp/soak/textshelf-daphne.json --sessions 3 --churn-every 90 --cwd /tmp/soak/textshelf -- \
  "$BIN" config.asgi --port 8505 --metrics
row textshelf_wsgi_pool8_no-abandon /tmp/soak/textshelf 8506 60 --capture /tmp/soak/textshelf-daphne.json --sessions 3 --abandon 0 --cwd /tmp/soak/textshelf -- \
  "$BIN" config.wsgi --port 8506 --metrics
echo "rerun done"
