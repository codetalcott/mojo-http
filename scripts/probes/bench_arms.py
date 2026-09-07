#!/usr/bin/env python3
"""Alternate pool arms under bench_threads.py; one JSON line each to OUT.

    python3 scripts/probes/bench_arms.py OUT ROUNDS CONNS [arm ...]

Arms: zc (zero-config), zc-eager (M0_POOL_ELASTIC=0), bt1, bt1-eager, bt2,
bt4, granian. Any arm may carry `@T` (M0_POOL_WAKE_AGE_US=T) and `=PATH`
(another m0serve binary, for an A/B against a different build — the
handoff-era `main-bt1`). Runs from the repository this file sits in; the
comparator is `.venv/bin/granian`. Absolute rates move 5–10 % across a
session on a laptop; alternate arms and read the ratios.
"""
import json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_threads.py")
OUT, ROUNDS, CONNS = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ARMS = sys.argv[4:] or ["zc", "zc-eager", "bt1"]
SPEC = ["bareapp.wsgi:application", "--app-dir", "apps/wsgi_bare"]


def arm(name):
    env = dict(os.environ)
    env.setdefault("BENCH_OUT", "/tmp/bench_threads")
    env["M0_POOL_DEBUG"] = "1"
    cwd = ROOT
    name_full = name
    name, _, srv = name.partition("=")
    srv = srv or os.path.join(ROOT, "bin", "m0serve")
    base, _, t = name.partition("@")
    if t:
        env["M0_POOL_WAKE_AGE_US"] = t
    name = base
    if name == "zc":
        cmd = [srv, *SPEC]
    elif name == "zc-eager":
        cmd = [srv, *SPEC]; env["M0_POOL_ELASTIC"] = "0"
    elif name == "bt1":
        cmd = [srv, *SPEC, "--workers", "1", "--blocking-threads", "1"]
    elif name == "bt1-eager":
        cmd = [srv, *SPEC, "--workers", "1", "--blocking-threads", "1"]; env["M0_POOL_ELASTIC"] = "0"
    elif name == "bt2":
        cmd = [srv, *SPEC, "--workers", "1", "--blocking-threads", "2"]
    elif name == "bt4":
        cmd = [srv, *SPEC, "--workers", "1", "--blocking-threads", "4"]
    elif name == "granian":
        cmd = [os.path.join(ROOT, ".venv", "bin", "granian"), "--interface", "wsgi", "--workers", "1",
               "--blocking-threads", "1", "--host", "127.0.0.1", "--port", os.environ.get("BENCH_PORT", "8089"),
               "--log-level", "warning", "bareapp.wsgi:application"]
        cwd = os.path.join(ROOT, "apps", "wsgi_bare")
    else:
        raise SystemExit(f"unknown arm {name}")
    extra = ["--worker-child"] if name == "granian" else []
    name = name_full.replace("@", "-t").replace("/", "_")
    r = subprocess.run([sys.executable, BENCH, name, "--dur", "8", "--conns", str(CONNS), *extra,
                        "--cwd", cwd, "--", *cmd], env=env, capture_output=True, text=True)
    line = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if not line.startswith("{"):
        line = json.dumps({"name": name, "error": (r.stdout + r.stderr)[-500:]})
    d = json.loads(line); d["round"] = rnd; d["conns"] = CONNS
    with open(OUT, "a") as f:
        f.write(json.dumps(d) + "\n")
    t = d.get("threads", {})
    per = next(iter(t.values()), []) if t else []
    print(f"r{rnd} {name:12s} conns={CONNS} rps={d.get('rps')} cores={d.get('cores')} p99={d.get('p99')} threads={per}", flush=True)
    try:
        for ln in open(f"{env['BENCH_OUT']}/{name}.server.log"):
            if "pool lane" in ln:
                print("   ", ln.strip(), flush=True)
    except OSError:
        pass
    time.sleep(3)


for rnd in range(1, ROUNDS + 1):
    for a in ARMS:
        arm(a)
print("done", flush=True)
