#!/usr/bin/env python3
"""Fast-route tail with N slow views in flight: Django, --workers 4
--blocking-threads 4, one fresh server per arm and round, arms alternated.

    python3 scripts/probes/bench_slow.py ARM [ARM ...]
    ROUNDS=3 SLOWS=0,1,2 python3 scripts/probes/bench_slow.py el eager

An ARM is `name[@T][=BIN][:VAR=VALUE,...]`: `name` is a label (a few are
recognised — `eager` sets M0_POOL_ELASTIC=0, `noage` M0_POOL_PARALLEL=0,
`onage` M0_POOL_PARALLEL=1; anything else is just a label), `@T` sets
M0_POOL_WAKE_AGE_US, `=BIN` runs another m0serve binary (an A/B against a
different build), and `:VAR=VALUE` sets any environment variable — so
`turn0:M0_POOL_TURN=0` and `gc:M0_APP=gcwrap.wsgi:application` are arms
too. Prints rps/p50/p90/p99/max per slow level. The tail this measures is
bimodal on a GIL build (docs/notes/elastic-pool.md); one run proves
nothing, three alternated rounds are the minimum worth quoting.
"""
import os, re, subprocess, sys, time, signal

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
PORT = int(os.environ.get("BENCH_PORT", "8080"))
HDRS = ["-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "-H", "Accept-Language: en-US,en;q=0.9", "-H", "Accept-Encoding: gzip, deflate, br",
        "-H", "Cache-Control: max-age=0", "-H", "Upgrade-Insecure-Requests: 1",
        "-H", "Sec-Fetch-Mode: navigate", "-H", "Sec-Fetch-Dest: document", "-H", f"Referer: http://127.0.0.1:{PORT}/"]
URL = f"http://127.0.0.1:{PORT}/"


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def healthy():
    for _ in range(150):
        if sh(["curl", "-s", "--fail", "-o", "/dev/null", URL]).returncode == 0:
            return True
        time.sleep(0.2)
    return False


def slow_loop(n):
    procs = []
    for _ in range(n):
        procs.append(subprocess.Popen(
            f"while :; do curl -s -o /dev/null --max-time 5 'http://127.0.0.1:{PORT}/slow?ms=200' || sleep 0.1; done",
            shell=True, preexec_fn=os.setsid))
    return procs


def stop_slow(procs):
    for p in procs:
        try: os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError: pass
    for p in procs: p.wait()


def field(out, pat):
    m = re.search(pat, out, re.M)
    return m.group(1) if m else "?"


def measure(label, slow):
    sh(["wrk", "-t2", "-c16", "-d4s", *HDRS, URL]); time.sleep(2)
    procs = slow_loop(slow); time.sleep(1)
    out = sh(["wrk", "-t2", "-c16", "-d8s", "--latency", *HDRS, URL]).stdout
    stop_slow(procs)
    print(f"{label:22s} slow={slow} rps {field(out, r'Requests/sec:\s+([\d.]+)'):>9} p50 {field(out, r'^\s+50%\s+(\S+)'):>9} p90 {field(out, r'^\s+90%\s+(\S+)'):>9} p99 {field(out, r'^\s+99%\s+(\S+)'):>9} max {field(out, r'Latency\s+\S+\s+\S+\s+(\S+)'):>9}", flush=True)


def run(arm, rnd):
    env = dict(os.environ, PATH=f"{ROOT}/.venv/bin:" + os.environ["PATH"])
    spec, _, extra = arm.partition(":")
    for kv in filter(None, extra.split(",")):
        k, _, v = kv.partition("=")
        env[k] = v
    spec, _, binary = spec.partition("=")
    name, _, t = spec.partition("@")
    if name == "eager": env["M0_POOL_ELASTIC"] = "0"
    if name == "noage": env["M0_POOL_PARALLEL"] = "0"
    if name == "onage": env["M0_POOL_PARALLEL"] = "1"
    if t: env["M0_POOL_WAKE_AGE_US"] = t
    binary = binary or f"{ROOT}/bin/m0serve"
    app = env.get("M0_APP", "djangoproj.wsgi:application")
    log = open(f"/tmp/bench_slow_{re.sub(r'[^A-Za-z0-9_.-]', '_', arm)}.log", "w")
    p = subprocess.Popen([binary, app, "--app-dir", f"{ROOT}/apps/django_wsgi",
                          "--port", str(PORT), "--workers", "4", "--blocking-threads", "4"],
                         cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        if not healthy():
            print(arm, "never healthy"); return
        for slow in [int(x) for x in os.environ.get("SLOWS", "0,1,2").split(",")]:
            measure(f"r{rnd+1} {arm}", slow)
    finally:
        for kid in sh(["pgrep", "-P", str(p.pid)]).stdout.split():
            try: os.kill(int(kid), signal.SIGTERM)
            except ProcessLookupError: pass
        p.send_signal(signal.SIGTERM); p.wait(15); time.sleep(3)


for rnd in range(int(os.environ.get("ROUNDS", "1"))):
    for a in sys.argv[1:]:
        run(a, rnd)
