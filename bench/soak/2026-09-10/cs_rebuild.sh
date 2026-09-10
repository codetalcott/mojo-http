#!/bin/bash
# color-separation in the recorded shape: job 1 is the BIG image, so
# /job/1/download/ and /media/outputs/.../big_separations.zip are the 4.7 MB
# class zips the record describes. Prints the three sizes the manifest pins.
set -u
cd /tmp/soak/color-separation
rm -f db.sqlite3; rm -rf media; find . -maxdepth 2 -name "*.zip" -path "*outputs*" -delete 2>/dev/null
.venv/bin/python manage.py migrate --noinput 2>&1 | tail -1
(PATH=/tmp/soak/color-separation/.venv/bin:$PATH gunicorn halftone_studio.wsgi -w 2 -b 127.0.0.1:8431 --log-level warning --timeout 600 > /tmp/soak/cs-gunicorn-rel.log 2>&1 & echo $! > /tmp/soak/cs-gunicorn.pid)
sleep 5
J=/tmp/soak/cs.jar; rm -f $J
tok=$(curl -s -c $J -b $J http://127.0.0.1:8431/ | grep -o 'name="csrfmiddlewaretoken" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')
echo "upload big -> $(curl -s -c $J -b $J -H 'Referer: http://127.0.0.1:8431/' -F "csrfmiddlewaretoken=$tok" -F 'image=@/tmp/soak/big.png;type=image/png' -o /dev/null -w '%{http_code} %{redirect_url}' http://127.0.0.1:8431/upload/)"
tok2=$(curl -s -c $J -b $J http://127.0.0.1:8431/job/1/ | grep -o 'name="csrfmiddlewaretoken" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')
echo "process -> $(curl -s -c $J -b $J -H 'Referer: http://127.0.0.1:8431/job/1/' -o /dev/null -w '%{http_code}' --data-urlencode "csrfmiddlewaretoken=$tok2" --data-urlencode mode=simulated --data-urlencode n_colors=6 --data-urlencode substrate=light --data-urlencode 'substrate_color=#FFFFFF' --data-urlencode lpi=45 --data-urlencode dpi=300 --data-urlencode print_order_strategy=luminance --data-urlencode physical_width=18.0 --data-urlencode physical_height=22.0 http://127.0.0.1:8431/job/1/process/)"
for i in $(seq 1 120); do st=$(curl -s -b $J http://127.0.0.1:8431/job/1/status/); echo "$st" | grep -q '"completed"\|"failed"' && break; sleep 3; done
echo "status: $(echo "$st" | cut -c1-80)"
for p in /job/1/download/ /media/outputs/2026/09/big_separations.zip /media/uploads/2026/09/big.png; do
  echo "SIZE $p $(curl -s -b $J -o /dev/null -w '%{http_code} %{size_download}' http://127.0.0.1:8431$p)"
done
kill $(cat /tmp/soak/cs-gunicorn.pid) 2>/dev/null; sleep 1
echo "rebuild done"
