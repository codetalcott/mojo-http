#!/usr/bin/env python3
"""The arms of `bench-linux-conclusions`, run INSIDE the Linux container.

    python3 bench_linux_arms.py            # run the arms, write /work/linux_arms.json
    python3 bench_linux_arms.py --record   # turn that into bench artifacts, print their paths

Driven by `scripts/bench_linux_conclusions.py` on the Mac; separate because
the arms must run where the server runs and the recorder must stamp the
machine that ran them (`bench_record.environment()` reads THIS host).

Three shapes, matching the three tables docs/BENCHMARKS.md renders, so each
conclusion has a Linux counterpart:

    asgi    the executor against uvicorn, with and without uvloop
    layer   the HTTP layer, the bridge inline, the pooled row, granian
    iso     the fast route's p99 as slow views are added, pool on and off

Every comparator is re-measured in every round and the arms alternate
within a round, because the ratio is the claim and a machine that drifts
mid-run would otherwise land entirely on one arm.
"""
import json, os, re, signal, subprocess, sys, time, statistics as st

WORK = "/work"; VENV = f"{WORK}/.venv/bin"; PORT = 8080
CLK = os.sysconf("SC_CLK_TCK")
OUT = f"{WORK}/linux_arms.json"
HDRS = ["-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "-H", "Accept-Language: en-US,en;q=0.9", "-H", "Accept-Encoding: gzip, deflate, br",
        "-H", "Cache-Control: max-age=0", "-H", "Upgrade-Insecure-Requests: 1",
        "-H", "Sec-Fetch-Mode: navigate", "-H", "Sec-Fetch-Dest: document",
        "-H", f"Referer: http://127.0.0.1:{PORT}/"]

def kids(pid):
    out = [pid]
    try:
        for k in subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split():
            out += kids(int(k))
    except Exception:
        pass
    return out

def ticks(pid):
    # utime+stime, which INCLUDE every thread of the process. `ps %cpu` is an
    # average over the process's whole lifetime on Linux and would report
    # nonsense for an eight-second window.
    try:
        f = open(f"/proc/{pid}/stat").read()
        x = f[f.rindex(")") + 2:].split()
        return int(x[11]) + int(x[12])
    except Exception:
        return 0

def tree(pid):
    return sum(ticks(p) for p in kids(pid))

def healthy(t=45):
    t0 = time.time()
    while time.time() - t0 < t:
        if subprocess.run(["curl", "-s", "--fail", "-o", "/dev/null",
                           f"http://127.0.0.1:{PORT}/"], capture_output=True).returncode == 0:
            return True
        time.sleep(0.2)
    return False

def wrk(conns, dur, lat=True):
    cmd = ["wrk", "-t2", f"-c{conns}", f"-d{dur}s"] + (["--latency"] if lat else []) \
        + HDRS + [f"http://127.0.0.1:{PORT}/"]
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def parse(o):
    def g(p, c=str):
        m = re.search(p, o, re.M)
        return c(m.group(1)) if m else None
    return dict(rps=g(r"Requests/sec:\s+([\d.]+)", float),
                p50=g(r"^\s+50%\s+(\S+)"), p99=g(r"^\s+99%\s+(\S+)"))

def us(s):
    if not s:
        return None
    m = re.match(r"([\d.]+)(us|ms|s)$", s)
    return float(m.group(1)) * {"us": 1, "ms": 1000, "s": 1e6}[m.group(2)] if m else None

def measure(name, cmd, conns, dur, env_extra=None, slow=0):
    env = dict(os.environ, PATH=f"{VENV}:" + os.environ["PATH"], **(env_extra or {}))
    p = subprocess.Popen(cmd, cwd=WORK, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    hogs = []
    try:
        if not healthy():
            return dict(name=name, error="never healthy")
        wrk(conns, 2, lat=False)
        for _ in range(slow):
            hogs.append(subprocess.Popen(
                ["bash", "-c", f'while :; do curl -s -m 5 "http://127.0.0.1:{PORT}/slow?ms=200" -o /dev/null || sleep 0.1; done'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if slow:
            time.sleep(1.0)
        t0, c0 = time.time(), tree(p.pid)
        out = wrk(conns, dur)
        t1, c1 = time.time(), tree(p.pid)
        r = parse(out)
        used = (c1 - c0) / CLK / (t1 - t0)
        return dict(name=name, rps=r["rps"], p50_us=us(r["p50"]), p99_us=us(r["p99"]),
                    cores=round(used, 3),
                    rps_per_core=round(r["rps"] / used) if r["rps"] and used > 0.01 else None)
    finally:
        for h in hogs:
            h.kill(); h.wait()
        for q in kids(p.pid)[1:]:
            try: os.kill(q, signal.SIGTERM)
            except OSError: pass
        p.send_signal(signal.SIGTERM)
        try: p.wait(15)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
        time.sleep(2)

M0 = f"{WORK}/bin/m0serve"
ASGI = ["bareapp.asgi:application", "--app-dir", "apps/asgi_bare", "--port", str(PORT)]
WSGI = ["bareapp.wsgi:application", "--app-dir", "apps/wsgi_bare", "--port", str(PORT)]
def uvi(loop):
    return [f"{VENV}/python", "-m", "uvicorn", "--app-dir", "apps/asgi_bare", "--host", "127.0.0.1",
            "--port", str(PORT), "--log-level", "critical", "--loop", loop, "bareapp.asgi:application"]

BENCHES = {
    "asgi": [("m0serve asgi-executor", [M0] + ASGI, {}),
             ("uvicorn asyncio", uvi("asyncio"), {}),
             ("uvicorn uvloop", uvi("uvloop"), {})],
    "layer": [("hello(no python,1proc)", ["/tmp/bench_hello_server"], {"M0_PORT": str(PORT)}),
              ("m0serve+bare w1 bt0", [M0] + WSGI + ["--workers", "1", "--blocking-threads", "0"], {}),
              ("m0serve+bare w1 bt1", [M0] + WSGI + ["--workers", "1", "--blocking-threads", "1"], {}),
              ("m0serve+bare zero-config", [M0] + WSGI, {}),
              ("granian+bare w1", [f"{VENV}/granian", "--interface", "wsgi", "--host", "127.0.0.1",
                                   "--port", str(PORT), "--workers", "1", "--blocking-threads", "1",
                                   "bareapp.wsgi:application"], {"PYTHONPATH": f"{WORK}/apps/wsgi_bare"})],
}
ISO = [("--workers 4 slow=%d", [M0] + WSGI + ["--workers", "4"]),
       ("--workers 4 +bt=4 slow=%d", [M0] + WSGI + ["--workers", "4", "--blocking-threads", "4"])]

NOTE = ("Linux arm of the conclusions pass, recorded in the m0lin container. NOT the "
        "benchmark page's row and not comparable to it in absolute terms -- a VM on a Mac, "
        "and server and client share its cpus. The RATIOS are the signal; every comparator "
        "was re-measured in every round and the per-arm spread is in the rows.")

def record():
    import bench_record as B
    rows_all = json.load(open(OUT))
    kinds = {"asgi": ("asgi_wrk_hello", {"client": "wrk -t2 -c16 -d8s, browser headers",
                                         "app": "apps/asgi_bare bareapp.asgi:application /"}),
             "layer": ("layer_split", {"client": "wrk -t2 -c16 -d10s, browser headers"}),
             "iso": ("mixed_workload", {"client": "wrk -t2 -c16 -d10s, browser headers", "hold_ms": "200"})}
    for bench, (kind, meta) in kinds.items():
        rows = [{k: v for k, v in r.items() if k != "bench"} for r in rows_all if r["bench"] == bench]
        if not rows:
            continue
        n = len({r["round"] for r in rows})
        print(B.write_artifact(kind, rows, dict(meta, rounds=str(n), note=NOTE)))

if __name__ == "__main__":
    sys.path.insert(0, f"{WORK}/scripts")
    if "--record" in sys.argv:
        record(); raise SystemExit(0)
    rounds = int(os.environ.get("ROUNDS", "3"))
    res = []
    for kind, arms in BENCHES.items():
        conns, dur = (16, 8) if kind == "asgi" else (16, 10)
        for r in range(1, rounds + 1):
            for name, cmd, env in arms:
                x = measure(name, cmd, conns, dur, env); x.update(bench=kind, round=r)
                res.append(x); print(json.dumps(x), flush=True)
    for r in range(1, rounds + 1):
        for tmpl, cmd in ISO:
            for slow in (0, 1, 2):
                x = measure(tmpl % slow, cmd, 16, 10, {}, slow); x.update(bench="iso", round=r)
                res.append(x); print(json.dumps(x), flush=True)
    open(OUT, "w").write(json.dumps(res, indent=2))
    bad = [r for r in res if r.get("error")]
    for b in bad:
        print(f"ARM FAILED: {b['name']}: {b['error']}", file=sys.stderr)
    # A spread report, so a contaminated run is visible rather than averaged.
    for b in sorted({r["bench"] for r in res}):
        for n in sorted({r["name"] for r in res if r["bench"] == b}):
            v = [r["rps"] for r in res if r["bench"] == b and r["name"] == n and r.get("rps")]
            if len(v) > 1:
                print(f"  spread {b:<6} {n:<28} {(max(v)-min(v))/st.median(v)*100:5.1f}%")
    raise SystemExit(1 if bad else 0)
