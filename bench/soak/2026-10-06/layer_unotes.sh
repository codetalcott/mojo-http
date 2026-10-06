#!/bin/bash
# The 2026-10-06 application-layer soak: unotes built by the m0 0.7.0 wheel
# cut from the release branch (framework 1.11.0), on its real corpus, held to
# a capture the same binary served one request at a time. The flags are the
# 2026-10-02 pass's (unotes' SOAK_LOG): six bursts, four sessions, two
# abandoners paced at 50 ms, no bulk population (it signs in unpaced; the
# manifest's finding 15), a SIGTERM and restart every 40 s.
#
#     layer_unotes.sh UNOTES_CHECKOUT    # bin/server built, data/ holding the corpus
#
# The corpus is the owner's and never leaves the checkout; the password is a
# throwaway the manifest names, not the deploy's.
set -u
U=$(cd "$1" && pwd) || exit 2
cd "$(dirname "$0")/../../.." || exit 1
OUT=./bin/soak-out
mkdir -p "$OUT"
export UNOTES_NOTES="$U/data/notes.sqlite" UNOTES_THEMES="$U/data/theme-map.md"
export UNOTES_PASSWORD=soak-pass UNOTES_SECURE=0 UNOTES_KEY="$(openssl rand -hex 32)"
# A forked worker opens SQLite after the fork on macOS (CLAUDE.md, runtime
# constraints).
export OS_ACTIVITY_MODE=disable
CAP="$OUT/unotes-capture.json"

echo "=== capture start $(date +%H:%M:%S)"
"$U/bin/server" --host 127.0.0.1 --port 8601 > "$OUT/unotes-capture-server.log" 2>&1 &
pid=$!
sleep 2
python3 scripts/soak.py --manifest "$U/tools/soak_manifest.json" \
  --url http://127.0.0.1:8601 --baseline "$CAP" > "$OUT/unotes-capture.out" 2>&1
echo "=== capture exit=$? $(date +%H:%M:%S)"; tail -2 "$OUT/unotes-capture.out"
kill "$pid"; wait "$pid" 2>/dev/null
sleep 2

row() {  # name port seconds -- serve command words
  local name=$1 port=$2 secs=$3; shift 4
  echo "=== $name start $(date +%H:%M:%S)"
  python3 scripts/soak.py --manifest "$U/tools/soak_manifest.json" \
    --url "http://127.0.0.1:$port" --seconds "$secs" --capture "$CAP" \
    --burst 6 --sessions 4 --bulk 0 --stream 0 --ws 0 \
    --abandon 2 --abandon-pause 0.05 --churn-every 40 \
    --log "$OUT/$name.log" --cwd "$U" --serve "$*" > "$OUT/$name.out" 2>&1
  echo "=== $name exit=$? $(date +%H:%M:%S)"; tail -3 "$OUT/$name.out" | cut -c1-160
  sleep 5
}
row unotes_workers2 8602 180 -- "$U/bin/server" --host 127.0.0.1 --port 8602 --workers 2
row unotes_threads2 8603 90 -- "$U/bin/server" --host 127.0.0.1 --port 8603 --threads 2
echo "layer soak done"
