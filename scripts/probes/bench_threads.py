#!/usr/bin/env python3
"""Run one server config under wrk; record rps, per-thread CPU (ps -M, medians),
and optionally a profile (`--sample-first` for /usr/bin/sample, `--xctrace` for
Instruments' Time Profiler, which is the one to trust for on-CPU shares).

    python3 scripts/probes/bench_threads.py NAME [--dur S] [--conns N] [--sample-first] [--xctrace]
        [--worker-child] [--cwd DIR] -- CMD...

CMD is the server; NAME.server.log, NAME.sample.txt / NAME.trace land in
BENCH_OUT (default: /tmp/bench_threads). Port 8089 unless BENCH_PORT.
Granian: pass --worker-child so the profile attaches to the worker, and
--cwd apps/wsgi_bare with ../../.venv/bin/granian. PATH gets .venv/bin first
so m0serve embeds the venv's Python. One JSON line per measurement:
{"rps", "p50", "p99", "threads": {pid: [%cpu per thread, creation order]},
"cores"}. The threads list is in creation order: for m0serve, [0] is the
loop and the last is the pool thread at --blocking-threads 1.
"""
import argparse, os, re, signal, subprocess, sys, time, statistics, json

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
# Never beside the script: an untracked output directory in the tree stamps
# the next bench artifact `git_dirty`.
SCR = os.environ.get("BENCH_OUT", "/tmp/bench_threads")
os.makedirs(SCR, exist_ok=True)
PORT = int(os.environ.get("BENCH_PORT", "8089"))
HDRS = ["-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "-H", "Accept-Language: en-US,en;q=0.9", "-H", "Accept-Encoding: gzip, deflate, br",
        "-H", "Cache-Control: max-age=0", "-H", "Upgrade-Insecure-Requests: 1",
        "-H", "Sec-Fetch-Mode: navigate", "-H", "Sec-Fetch-Dest: document", "-H", f"Referer: http://127.0.0.1:{PORT}/"]
URL = f"http://127.0.0.1:{PORT}/"
XCTRACE = False

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def listen_pids():
    r = sh(["lsof", "-nP", "-t", f"-iTCP:{PORT}", "-sTCP:LISTEN"])
    return sorted({int(x) for x in r.stdout.split()})

def ps_threads(pid):
    """[(tid_index, cpu%)] for a pid via ps -M."""
    r = sh(["ps", "-M", "-p", str(pid)])
    rows = []
    for line in r.stdout.splitlines()[1:]:
        toks = line.split()
        # rows: USER PID TT %CPU STAT ... or continuation: PID? ... find first float token followed by a STAT-ish token
        for i, t in enumerate(toks):
            if re.fullmatch(r"\d+\.\d", t) and i + 1 < len(toks) and re.fullmatch(r"[A-Za-z+<>]+", toks[i + 1]):
                rows.append(float(t)); break
    return rows

def wait_healthy(timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = sh(["curl", "-s", "--fail", "-o", "/dev/null", URL])
        if r.returncode == 0:
            return True
        time.sleep(0.2)
    return False

def wrk(dur, conns):
    return subprocess.Popen(["wrk", "-t2", f"-c{conns}", f"-d{dur}s", "--latency", *HDRS, URL],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

def parse_wrk(out):
    rps = re.search(r"Requests/sec:\s+([\d.]+)", out)
    p50 = re.search(r"^\s+50%\s+(\S+)", out, re.M)
    p99 = re.search(r"^\s+99%\s+(\S+)", out, re.M)
    errs = re.search(r"Socket errors:.*", out)
    return (float(rps.group(1)) if rps else None, p50.group(1) if p50 else "?", p99.group(1) if p99 else "?", errs.group(0) if errs else "")

def measure(name, dur, conns, do_sample, sample_pid):
    w = wrk(dur, conns)
    per_pid = {}
    samp = None
    t0 = time.time()
    while w.poll() is None:
        for pid in listen_pids():
            per_pid.setdefault(pid, []).append(ps_threads(pid))
        el = time.time() - t0
        if do_sample and samp is None and el >= 2.0:
            if XCTRACE:
                samp = subprocess.Popen(["xctrace", "record", "--template", "Time Profiler", "--attach", str(sample_pid), "--time-limit", "5s", "--output", f"{SCR}/{name}.trace"],
                                        stdout=open(f"{SCR}/{name}.xctrace.log", "w"), stderr=subprocess.STDOUT)
            else:
                samp = subprocess.Popen(["sample", str(sample_pid), "5", "-mayDie", "-file", f"{SCR}/{name}.sample.txt"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.0)
    out = w.communicate()[0]
    if samp: samp.wait()
    rps, p50, p99, errs = parse_wrk(out)
    # per-thread medians: align by thread index (ps -M lists threads in creation order)
    summary = {}
    for pid, snaps in per_pid.items():
        snaps = [s for s in snaps if s]
        if not snaps: continue
        n = max(len(s) for s in snaps)
        meds = []
        for i in range(n):
            vals = [s[i] for s in snaps if len(s) > i]
            meds.append(round(statistics.median(vals), 1))
        summary[pid] = meds
    total = sum(sum(v) for v in summary.values()) / 100.0
    return dict(name=name, rps=rps, p50=p50, p99=p99, errs=errs, threads=summary, cores=round(total, 2), sampled=do_sample)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name"); ap.add_argument("--dur", type=int, default=8); ap.add_argument("--conns", type=int, default=16)
    ap.add_argument("--sample", action="store_true"); ap.add_argument("--sample-first", action="store_true"); ap.add_argument("--xctrace", action="store_true"); ap.add_argument("--cwd", default=ROOT)
    ap.add_argument("--worker-child", action="store_true", help="sample the child of the launched pid (granian)")
    argv = sys.argv[1:]
    cut = argv.index("--")
    a = ap.parse_args(argv[:cut])
    global XCTRACE
    XCTRACE = a.xctrace
    cmd = argv[cut + 1:]
    env = dict(os.environ, PATH=f"{ROOT}/.venv/bin:" + os.environ["PATH"], M0_PORT=str(PORT))
    if listen_pids():
        print(f"port {PORT} busy: {listen_pids()}", file=sys.stderr); sys.exit(2)
    log = open(f"{SCR}/{a.name}.server.log", "w")
    p = subprocess.Popen(cmd, cwd=a.cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_healthy():
            print(f"{a.name}: never healthy", file=sys.stderr); sys.exit(1)
        sample_pid = p.pid
        if a.worker_child:
            time.sleep(0.5)
            kids = sh(["pgrep", "-P", str(p.pid)]).stdout.split()
            if kids: sample_pid = int(kids[-1])
        wrk(3, a.conns).communicate()  # warm
        results = [measure(a.name, a.dur, a.conns, a.sample_first, sample_pid)]
        if a.sample:
            results.append(measure(a.name, a.dur, a.conns, True, sample_pid))
        for r in results:
            print(json.dumps(r))
    finally:
        for kid in sh(["pgrep", "-P", str(p.pid)]).stdout.split():
            try: os.kill(int(kid), signal.SIGTERM)
            except ProcessLookupError: pass
        p.send_signal(signal.SIGTERM)
        try: p.wait(10)
        except subprocess.TimeoutExpired: p.kill()
        log.close()

if __name__ == "__main__":
    main()
