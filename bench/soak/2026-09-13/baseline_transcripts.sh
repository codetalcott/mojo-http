set -x
cd /tmp/soak/transcripts
PYTHONPATH=/tmp/soak/transcripts/src PATH=/tmp/soak/transcripts/.venv/bin:$PATH \
  gunicorn transcript_manager.wsgi -w 2 -b 127.0.0.1:8411 --log-level warning --timeout 600 \
  > /tmp/soak/tr-gunicorn.log 2>&1 &
echo $! > /tmp/soak/tr-gunicorn.pid
sleep 6
curl -s -o /dev/null -w "root=%{http_code}\n" http://127.0.0.1:8411/
curl -s -o /dev/null -w "student=%{http_code}\n" http://127.0.0.1:8411/student/1/
cd /private/tmp/claude-501/-Users-williamtalcott-projects-mojo-http/7d0788cc-5265-46af-b76f-be3f855e2067/scratchpad/rel
PATH=/tmp/soak/transcripts/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/transcripts.json \
  --url http://127.0.0.1:8411 --baseline /tmp/soak/transcripts-gunicorn.json 2>&1 | tail -20
kill $(cat /tmp/soak/tr-gunicorn.pid) 2>/dev/null
