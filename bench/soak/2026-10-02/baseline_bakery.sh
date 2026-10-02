set -x
cd /tmp/soak/bakerydemo
PATH=/tmp/soak/bakerydemo/.venv/bin:$PATH gunicorn bakerydemo.wsgi -w 2 -b 127.0.0.1:8313 \
  --log-level warning --timeout 600 > /tmp/soak/bakery-gunicorn.log 2>&1 &
echo $! > /tmp/soak/bakery-gunicorn.pid
sleep 8
curl -s -o /dev/null -w "root=%{http_code}\n" http://127.0.0.1:8313/
cd /Users/williamtalcott/projects/mojo-http
PATH=/tmp/soak/bakerydemo/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/bakerydemo.json \
  --url http://127.0.0.1:8313 --baseline /tmp/soak/bakerydemo-gunicorn.json 2>&1 | tail -30
kill $(cat /tmp/soak/bakery-gunicorn.pid) 2>/dev/null
