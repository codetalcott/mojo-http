set -x
cd /tmp/soak/textshelf
export DATABASE_URL="postgres://postgres@localhost:5432/textshelf_soak"
export DJANGO_SETTINGS_MODULE=config.settings.local
PATH=/tmp/soak/textshelf/.venv/bin:$PATH daphne -b 127.0.0.1 -p 8401 config.asgi:application \
  > /tmp/soak/ts-daphne.log 2>&1 &
echo $! > /tmp/soak/ts-daphne.pid
sleep 8
curl -s -o /dev/null -w "root=%{http_code}\n" http://127.0.0.1:8401/
curl -s -o /dev/null -w "login=%{http_code}\n" http://127.0.0.1:8401/accounts/login/
cd /Users/williamtalcott/projects/mojo-http
PATH=/tmp/soak/textshelf/.venv/bin:$PATH python3 scripts/soak.py \
  --manifest scripts/soak_manifests/textshelf.json \
  --url http://127.0.0.1:8401 --baseline /tmp/soak/textshelf-daphne.json 2>&1 | tail -25
kill $(cat /tmp/soak/ts-daphne.pid) 2>/dev/null
