set -x
cd /tmp/soak/transcripts
PYTHONPATH=/tmp/soak/transcripts/src PATH=/tmp/soak/transcripts/.venv/bin:$PATH \
  gunicorn transcript_manager.wsgi -w 2 -b 127.0.0.1:8411 --log-level warning --timeout 600 \
  > /tmp/soak/tr-gunicorn.log 2>&1 &
echo $! > /tmp/soak/tr-gunicorn.pid
sleep 6
curl -s -o /dev/null -w "root=%{http_code}\n" http://127.0.0.1:8411/
curl -s -o /dev/null -w "student=%{http_code}\n" http://127.0.0.1:8411/student/1/
cd /Users/williamtalcott/projects/mojo-http
PATH=/tmp/soak/transcripts/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/transcripts.json \
  --url http://127.0.0.1:8411 --baseline /tmp/soak/transcripts-gunicorn.json 2>&1 | tail -20
kill $(cat /tmp/soak/tr-gunicorn.pid) 2>/dev/null
