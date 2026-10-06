"""Per-round A/B: fresh server per arm, arms alternated every round, CPU from ps cumulative time."""
import os, re, subprocess, sys, time, statistics as st, json
W = "/Users/williamtalcott/projects/mojo-http/.claude/worktrees/asgi-per-core"
PORT = int(os.environ.get("PORT", "18741")); CONNS = int(os.environ.get("CONNS", "16")); ROUNDS = int(os.environ.get("ROUNDS", "6"))
HDRS = ["-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "-H", "Accept-Language: en-US,en;q=0.9", "-H", "Accept-Encoding: gzip, deflate, br"]
env0 = dict(os.environ, PATH=f"{W}/.venv/bin:" + os.environ["PATH"])
M0 = [f"{W}/bin/m0serve", "bareapp.asgi:application", "--app-dir", "apps/asgi_bare", "--port", str(PORT)]
UV = [f"{W}/.venv/bin/python", "-m", "uvicorn", "--app-dir", "apps/asgi_bare", "--host", "127.0.0.1", "--port", str(PORT),
      "--log-level", "critical", "--loop", "uvloop", "bareapp.asgi:application"]
ARMS = [("ring off", M0, {"M0_EXEC_RING": "0"}), ("ring on", M0, {"M0_EXEC_RING": "1"}), ("uvloop", UV, {})]
if os.environ.get("INVERTED"): ARMS = [(n + " inverted", c, dict(e, M0_INVERTED="1")) if c is M0 else (n, c, e) for n, c, e in ARMS]
def cpu(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    parts = [float(x) for x in out.replace("-", ":").split(":")]; s = 0.0
    for x in parts: s = s * 60 + x
    return s
def wrk(d, lat=False):
    return subprocess.run(["wrk", "-t2", f"-c{CONNS}", f"-d{d}s"] + (["--latency"] if lat else []) + HDRS + [f"http://127.0.0.1:{PORT}/"], capture_output=True, text=True).stdout
res = []
for r in range(1, ROUNDS + 1):
    for name, cmd, extra in ARMS:
        p = subprocess.Popen(cmd, cwd=W, env=dict(env0, **extra), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if subprocess.run(["curl", "-s", "-o", "/dev/null", "--fail", f"http://127.0.0.1:{PORT}/"]).returncode == 0: break
            time.sleep(0.1)
        wrk(2)
        c0, t0 = cpu(p.pid), time.time(); out = wrk(8, True); c1, t1 = cpu(p.pid), time.time()
        rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1)); cores = (c1 - c0) / (t1 - t0)
        p50 = re.search(r"50%\s+([\d.]+\w+)", out).group(1)
        res.append(dict(round=r, name=name, rps=rps, cores=cores, per_core=rps / cores, p50=p50)); print(json.dumps(res[-1]), flush=True)
        p.terminate(); p.wait(); time.sleep(2)
for n in [a[0] for a in ARMS]:
    v = [x for x in res if x["name"] == n]
    print(f"{n:<22} rps med {st.median(x['rps'] for x in v):9.0f} [{min(x['rps'] for x in v):.0f}-{max(x['rps'] for x in v):.0f}]  cores {st.median(x['cores'] for x in v):.2f}  per-core med {st.median(x['per_core'] for x in v):8.0f} [{min(x['per_core'] for x in v):.0f}-{max(x['per_core'] for x in v):.0f}]")
