#!/usr/bin/env python3
"""What the Mojo mount is worth, measured against Python in the same process.

`smoke-mojo-mount` proves the Mojo mount is isolated from the GIL, using two
trivial routes. That says the seam works; it does not say why you would want
it. This says why.

One `m0serve` hosts both arms. `/search` on the Python mount is numpy's best
shape for the job -- at a selectivity it gathers the eligible rows and hands
one contiguous matvec to BLAS, which beats scoring everything and masking.
What it cannot avoid is the gather, and the gather holds the GIL. `/native/
search` is the same answer from a fused Mojo loop that checks a row's tag
before touching its floats.

Both arms generate the same corpus from the same LCG, so the top-k must
agree exactly -- asserted before any timing is taken, because a benchmark of
two different computations is not a benchmark.

Cores are MEASURED, from the delta of the process's cumulative CPU time over
wall. macOS `ps -o pcpu` is a decaying average and under-reports a process
that just started; it produced wrong numbers here before this did.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from bench_record import write_artifact  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parent.parent
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    import traceback
    traceback.print_exception(kind, exc, tb)
    print("bench_mojo_mount FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def _cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = [float(p) for p in out.split(":")]
    return parts[0] * 3600 + parts[1] * 60 + parts[2] if len(parts) == 3 \
        else parts[0] * 60 + parts[1]


def _get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read())


def _wrk(url, conns, secs):
    out = subprocess.run(
        ["wrk", "-t4", f"-c{conns}", f"-d{secs}s", "--latency", url],
        capture_output=True, text=True).stdout
    rps = p50 = p99 = None
    for line in out.splitlines():
        s = line.split()
        if line.startswith("Requests/sec:"):
            rps = float(s[1])
        elif s and s[0] == "50%":
            p50 = s[1]
        elif s and s[0] == "99%":
            p99 = s[1]
    return rps, p50, p99


def _us(text):
    if text is None:
        return None
    for suffix, mult in (("us", 1.0), ("ms", 1000.0), ("s", 1e6)):
        if text.endswith(suffix):
            return round(float(text[: -len(suffix)]) * mult, 1)
    return None


def measure(pid, url, conns, secs):
    _wrk(url, conns, 2)                       # warm
    c0, w0 = _cpu_seconds(pid), time.perf_counter()
    rps, p50, p99 = _wrk(url, conns, secs)
    c1, w1 = _cpu_seconds(pid), time.perf_counter()
    cores = (c1 - c0) / (w1 - w0) if None not in (c0, c1) else None
    return {
        "rps": round(rps, 1) if rps else None,
        "cores": round(cores, 2) if cores else None,
        "rps_per_core": int(rps / cores) if rps and cores else None,
        "p50_us": _us(p50),
        "p99_us": _us(p99),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8811)
    ap.add_argument("--conns", type=int, default=8)
    ap.add_argument("--secs", type=int, default=5)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--sel", default="100,25,5")
    args = ap.parse_args()

    base = f"http://127.0.0.1:{args.port}"

    # A busy laptop and a committed artifact are the thing this stands
    # between; `bench_layer_split.sh` waits the same way.
    phase("waiting for a quiet machine")
    guard = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bench_guard.py"), "wait",
         "--threshold", "50", "--samples", "3", "--timeout", "120"])
    if guard.returncode != 0:
        sys.exit("bench_guard: the machine did not go quiet")

    phase("starting the two-mount server")
    log = open(REPO / "mojo_mount_bench.log", "w")
    srv = subprocess.Popen(
        [str(REPO / "bin" / "m0serve"),
         "--mount", "/=app:application", "--mount", "/native=mojo",
         "--app-dir", str(REPO / "bench" / "mojo_mount"),
         "--port", str(args.port), "--blocking-threads", str(args.threads)],
        stdout=log, stderr=subprocess.STDOUT)
    try:
        for _ in range(120):
            try:
                _get(base + "/")
                break
            except Exception:
                time.sleep(0.5)
        else:
            # Print what the server said. Swallowing it cost an hour here:
            # `bin/m0serve` embeds the interpreter on PATH, so under
            # `uv run poe` that is the tree's venv, and a missing numpy read
            # as "never became healthy" with no other clue.
            log.flush()
            said = (REPO / "mojo_mount_bench.log").read_text()
            sys.exit("server never became healthy; it said:\n" + said)

        phase("asserting both arms compute the same answer")
        sels = [int(s) for s in args.sel.split(",")]
        for sel in sels:
            py = _get(f"{base}/search?sel={sel}")["top"]
            mo = _get(f"{base}/native/search?sel={sel}")["top"]
            if py != mo:
                sys.exit(f"arms disagree at sel={sel}: python {py} mojo {mo}")
        print(f"both arms agree at sel={sels}")

        phase("measuring")
        rows = []
        for rnd in range(1, args.rounds + 1):
            for sel in sels:
                for name, path in (("python", "/search"),
                                   ("mojo", "/native/search")):
                    r = measure(srv.pid, f"{base}{path}?sel={sel}",
                                args.conns, args.secs)
                    r.update(round=rnd, name=f"{name}(sel={sel})")
                    rows.append(r)
                    print(f"  r{rnd} {r['name']:<16} rps={r['rps']:<9} "
                          f"cores={r['cores']:<6} /core={r['rps_per_core']:<8} "
                          f"p99={r['p99_us']}us")
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=15)
        except subprocess.TimeoutExpired:
            srv.kill()

    phase("writing the artifact")
    write_artifact("mojo_mount", rows, {
        "duration": f"{args.secs}s", "connections": str(args.conns),
        "rounds": str(args.rounds), "blocking_threads": str(args.threads),
        "corpus": "4096x256 f32, LCG seed 20260910",
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
