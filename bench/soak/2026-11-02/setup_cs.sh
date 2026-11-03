#!/bin/bash
# color-separation for the 1.17.0 re-soak, at b927272 (cloned by hand first:
# git clone ~/projects/color-separation /tmp/soak/color-separation).
# output/ is tracked at this commit, so nothing is copied in.
# venv from its uv.lock (Python from .python-version, 3.12), gunicorn and
# uvicorn added; the seeded fixtures (scripts/soak_fixtures.py, seed
# 20260910) into /tmp/soak; then bench/soak/2026-09-10/cs_rebuild.sh's
# sequence: job 1 = big.png processed with n_colors=6 (the form's default 8
# fails spot mode's validator). The manifest names media under 2026/09, and
# media is filed by month, so 2026/09 is made a symlink to this month's
# directory (as 2026-10-02 did with 10).
set -u
TREE=/Users/williamtalcott/projects/mojo-http-fdfit
PORT=8431
cd /tmp/soak/color-separation
git log -1 --format='checkout %h %s'
uv sync --python 3.12 2>&1 | tail -2
uv pip install --python .venv/bin/python gunicorn==26.2.0 uvicorn 2>&1 | tail -3
.venv/bin/python --version
.venv/bin/python -c 'import django, PIL, numpy, gunicorn, uvicorn; print("django", django.__version__, "pillow", PIL.__version__, "numpy", numpy.__version__, "gunicorn", gunicorn.__version__, "uvicorn", uvicorn.__version__)'
.venv/bin/python "$TREE/scripts/soak_fixtures.py" --out /tmp/soak

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy"; exit 1; fi
rm -f db.sqlite3; rm -rf media
.venv/bin/python manage.py migrate --noinput 2>&1 | tail -1
(PATH=/tmp/soak/color-separation/.venv/bin:$PATH gunicorn halftone_studio.wsgi -w 2 -b 127.0.0.1:$PORT --log-level warning --timeout 600 > /tmp/soak/cs-gunicorn-rel.log 2>&1 & echo $! > /tmp/soak/cs-gunicorn.pid)
sleep 5
J=/tmp/soak/cs.jar; rm -f $J
tok=$(curl -s -c $J -b $J http://127.0.0.1:$PORT/ | grep -o 'name="csrfmiddlewaretoken" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')
echo "upload big -> $(curl -s -c $J -b $J -H "Referer: http://127.0.0.1:$PORT/" -F "csrfmiddlewaretoken=$tok" -F 'image=@/tmp/soak/big.png;type=image/png' -o /dev/null -w '%{http_code} %{redirect_url}' http://127.0.0.1:$PORT/upload/)"
tok2=$(curl -s -c $J -b $J http://127.0.0.1:$PORT/job/1/ | grep -o 'name="csrfmiddlewaretoken" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')
echo "process -> $(curl -s -c $J -b $J -H "Referer: http://127.0.0.1:$PORT/job/1/" -o /dev/null -w '%{http_code}' --data-urlencode "csrfmiddlewaretoken=$tok2" --data-urlencode mode=simulated --data-urlencode n_colors=6 --data-urlencode substrate=light --data-urlencode 'substrate_color=#FFFFFF' --data-urlencode lpi=45 --data-urlencode dpi=300 --data-urlencode print_order_strategy=luminance --data-urlencode physical_width=18.0 --data-urlencode physical_height=22.0 http://127.0.0.1:$PORT/job/1/process/)"
for i in $(seq 1 120); do st=$(curl -s -b $J http://127.0.0.1:$PORT/job/1/status/); echo "$st" | grep -q '"completed"\|"failed"' && break; sleep 3; done
echo "status: $(echo "$st" | cut -c1-120)"
M=$(date +%m)
for d in uploads outputs; do
  if [ "$M" != 09 ] && [ -d "media/$d/2026/$M" ] && [ ! -e "media/$d/2026/09" ]; then
    ln -s "$M" "media/$d/2026/09"; echo "linked media/$d/2026/09 -> $M"
  fi
done
ls -la media/uploads/2026 media/outputs/2026
for p in /job/1/download/ /media/outputs/2026/09/big_separations.zip /media/uploads/2026/09/big.png; do
  echo "SIZE $p $(curl -s -b $J -o /dev/null -w '%{http_code} %{size_download}' http://127.0.0.1:$PORT$p)"
done
PID=$(cat /tmp/soak/cs-gunicorn.pid)
kill "$PID" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -0 "$PID" 2>/dev/null && echo "gunicorn $PID still alive" || echo "gunicorn $PID stopped"
echo "rebuild done"
