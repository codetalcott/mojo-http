#!/bin/sh
# Probe `deploy/mojo-hello/Dockerfile`'s image from OUTSIDE, the way
# `scripts/demo_probe.py` probes the Django demo's (M17): published port,
# no reaching into the container to make it work.
#
#     scripts/mojo_image_probe.sh [IMAGE]
#
# What the pure-Mojo image has to answer: it serves, the binary is PID 1,
# `docker stop` is a drain that exits 0, and the size and RSS are worth
# recording beside the Django demo's (52 MB RSS per worker, 74 MiB image).
set -e
IMG="${1:-m0-hello-spike:arm64}"
NAME="m0spike$$"
PORT=18099

fail() { echo "FAIL: $*" >&2; docker rm -f "$NAME" >/dev/null 2>&1 || true; exit 1; }

echo "== image"
docker image inspect "$IMG" --format 'size: {{.Size}} bytes ({{.Os}}/{{.Architecture}})'

docker run -d --name "$NAME" -p "$PORT:8080" "$IMG" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

echo "== serves"
i=0
until curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && fail "never became healthy"
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$PORT/health"; echo
curl -fsS "http://127.0.0.1:$PORT/" ; echo

echo "== PID 1"
# `docker exec ... < /proc/1/cmdline` would redirect from the HOST's own
# pid 1. The read has to happen inside the container.
cmd=$(docker exec "$NAME" sh -c "tr '\\0' ' ' < /proc/1/cmdline")
echo "pid 1: $cmd"
# Exactly the binary, not merely a command line mentioning it: a
# `sh -c /app/hello` entrypoint contains the name, is not PID 1, and does not
# forward SIGTERM (that sabotage exits 137, which only the drain phase below
# caught while this check matched on a substring).
set -- $cmd
if [ "$#" -ne 1 ] || [ "$1" != "/app/hello" ]; then
  fail "the binary is not PID 1: $cmd"
fi

echo "== no interpreter in the image"
if docker exec "$NAME" sh -c 'command -v python3 || command -v python' 2>/dev/null; then
  fail "a python interpreter is present"
fi
echo "none"

echo "== RSS, idle"
docker exec "$NAME" grep VmRSS /proc/1/status

echo "== RSS, 100 connections held open"
python3 - "$PORT" <<'PYEOF'
import socket, sys, time
port = int(sys.argv[1])
socks = []
for _ in range(100):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
    s.recv(4096)
    socks.append(s)
print(f"{len(socks)} keep-alive connections answered and held")
time.sleep(3)
PYEOF
docker exec "$NAME" grep VmRSS /proc/1/status

echo "== drain"
start=$(date +%s)
docker stop -t 20 "$NAME" >/dev/null
elapsed=$(( $(date +%s) - start ))
code=$(docker inspect "$NAME" --format '{{.State.ExitCode}}')
echo "docker stop: exit $code in ${elapsed}s"
[ "$code" = "0" ] || fail "SIGTERM did not drain cleanly (exit $code)"
echo
echo "PASS"
