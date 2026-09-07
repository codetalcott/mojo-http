#!/bin/bash
# The 2026-09-04 re-soak's six rows against this tree's bin/m0serve, one
# after another, driver output per row. Same driver, same populations, same
# durations and churn cadences; the baselines were re-captured today.
cd "$(dirname "$0")/.."
OUT=./out
BIN=$PWD/bin/m0serve
row() {  # name venv url-port seconds extra-driver-args... -- serve command words
  local name=$1 venv=$2 port=$3 secs=$4; shift 4
  local args=(); while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  echo "=== $name start $(date +%H:%M:%S)"
  PATH="$venv/.venv/bin:$PATH" python3 scripts/soak.py --manifest "scripts/soak_manifests/${name%%_*}.json" \
    --url "http://127.0.0.1:$port" --seconds "$secs" --log "$OUT/$name.log" "${args[@]}" \
    --serve "$*" > "$OUT/$name.out" 2>&1
  echo "=== $name exit=$? $(date +%H:%M:%S)"; tail -3 "$OUT/$name.out" | cut -c1-160
  sleep 5
}
row transcripts_wsgi_pool8_churn /tmp/soak/transcripts 8501 150 --capture /tmp/soak/transcripts-gunicorn.json --churn-every 60 --cwd /tmp/soak/transcripts -- \
  "$BIN" transcript_manager.wsgi --app-dir src --port 8501 --metrics
row bakerydemo_wsgi_pool8_churn /tmp/soak/bakerydemo 8502 180 --capture /tmp/soak/bakerydemo-gunicorn.json --sessions 4 --churn-every 75 --cwd /tmp/soak/bakerydemo -- \
  "$BIN" bakerydemo.wsgi --app-dir /tmp/soak/bakerydemo --port 8502 --metrics
row color-separation_wsgi_pool8_uploads_churn /tmp/soak/color-separation 8503 120 --capture /tmp/soak/cs-gunicorn.json --churn-every 60 --cwd /tmp/soak/color-separation -- \
  "$BIN" halftone_studio.wsgi --max-body 64m --port 8503 --metrics
row color-separation_asgi_executor /tmp/soak/color-separation 8504 90 --capture /tmp/soak/cs-uvicorn.json --cwd /tmp/soak/color-separation -- \
  "$BIN" halftone_studio.asgi --max-body 64m --port 8504 --metrics
export DATABASE_URL="postgres://postgres:REDACTED@localhost:5432/textshelf_soak" DJANGO_SETTINGS_MODULE=config.settings.local
row textshelf_asgi_executor_churn /tmp/soak/textshelf 8505 180 --capture /tmp/soak/textshelf-daphne.json --sessions 3 --churn-every 90 --cwd /tmp/soak/textshelf -- \
  "$BIN" config.asgi --port 8505 --metrics
row textshelf_wsgi_pool8_no-abandon /tmp/soak/textshelf 8506 60 --capture /tmp/soak/textshelf-daphne.json --sessions 3 --abandon 0 --cwd /tmp/soak/textshelf -- \
  "$BIN" config.wsgi --port 8506 --metrics
echo "soak rows done"
