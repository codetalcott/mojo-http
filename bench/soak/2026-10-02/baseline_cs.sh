set -x
cd /tmp/soak/color-separation
PATH=/tmp/soak/color-separation/.venv/bin:$PATH gunicorn halftone_studio.wsgi -w 2 -b 127.0.0.1:8431 \
  --log-level warning --timeout 600 > /tmp/soak/cs-gunicorn.log 2>&1 &
echo $! > /tmp/soak/cs-gunicorn.pid
sleep 6
cd /Users/williamtalcott/projects/mojo-http
PATH=/tmp/soak/color-separation/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/color-separation.json \
  --url http://127.0.0.1:8431 --baseline /tmp/soak/cs-gunicorn.json 2>&1 | tail -20
kill $(cat /tmp/soak/cs-gunicorn.pid) 2>/dev/null
sleep 3
cd /tmp/soak/color-separation
PATH=/tmp/soak/color-separation/.venv/bin:$PATH uvicorn halftone_studio.asgi:application \
  --host 127.0.0.1 --port 8444 --log-level warning > /tmp/soak/cs-uvicorn.log 2>&1 &
echo $! > /tmp/soak/cs-uvicorn.pid
sleep 6
cd /Users/williamtalcott/projects/mojo-http
PATH=/tmp/soak/color-separation/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/color-separation.json \
  --url http://127.0.0.1:8444 --baseline /tmp/soak/cs-uvicorn.json 2>&1 | tail -20
kill $(cat /tmp/soak/cs-uvicorn.pid) 2>/dev/null
