"""Blobs on a Fly shared-cpu-1x: V viewers through the proxy, the server's CPU read inside the machine.

    python3 fly_load.py APP "10:zstd,10:none,150:zstd" SECS
"""
import json, subprocess, sys, time
from pathlib import Path
APP, HOST = sys.argv[1], sys.argv[1] + ".fly.dev"
ARMS = [a.split(":") for a in sys.argv[2].split(",")]  # viewers:offer(zstd|none)
SECS = float(sys.argv[3])
W = str(Path(__file__).resolve().parents[3])
PY = sys.executable
READ = "sh -c 'cat /proc/uptime; for d in /proc/[0-9]*; do [ \"$(cat $d/comm 2>/dev/null)\" = server ] && cat $d/stat; done'"
def sample():
    out = subprocess.run(["fly", "ssh", "console", "-a", APP, "-C", READ], capture_output=True, text=True, timeout=60).stdout
    lines = [l for l in out.splitlines() if l.strip()]
    up = float(lines[0].split()[0])
    ticks = 0
    for l in lines[1:]:
        f = l.rsplit(")", 1)[1].split()
        ticks += int(f[11]) + int(f[12])  # utime, stime (fields 14, 15)
    return up, ticks
rows = []
for v, offer in ARMS:
    v = int(v)
    cl = subprocess.Popen([PY, W + "/scripts/bench_blobs_modes.py", "client", "--host", HOST, "--port", "80",
                           "--viewers", str(v), "--warm", "8", "--secs", str(SECS),
                           "--offer", "gzip, deflate, br, zstd" if offer == "zstd" else "gzip, deflate, br"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    s0 = s1 = None
    res = None
    for line in cl.stdout:
        line = line.strip()
        if line == "START":
            s0 = sample()
        elif line == "END":
            s1 = sample()
        elif line.startswith("{"):
            res = json.loads(line)
    cl.wait()
    if res is None or s0 is None or s1 is None:
        print("client failed:", cl.stderr.read()[-1500:]); sys.exit(1)
    cores = (s1[1] - s0[1]) / 100.0 / (s1[0] - s0[0])
    r = {"viewers": v, "offer": offer, "cores": round(cores, 4), "machine_s": round(s1[0] - s0[0], 1), **res}
    rows.append(r)
    print(f"v{v} {offer:<4} cores {cores:.4f} over {s1[0]-s0[0]:.1f}s  coded {res['coded_streams']} ratio {res['ratio']} "
          f"wire {res['wire_kBps_per_viewer']}kB/s deliv {res['delivered']} spread p99 {res['spread_p99_ms']}ms "
          f"min frames {res['viewers_min_frames']} step {res['step_us']}us", flush=True)
    time.sleep(10)
print(json.dumps(rows))
