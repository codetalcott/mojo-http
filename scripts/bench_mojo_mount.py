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
    comparisons = compare(rows, sels)
    print("\nmojo / python, median of within-round ratios "
          "[ratio of the medians block]:")
    for sel in sels:
        c = comparisons["by_sel"][str(sel)]
        print(f"  sel={sel:<3}  thru {c['throughput']:.2f}x "
              f"[{c['throughput_of_medians']:.2f}x]  per core "
              f"{c['per_core']:.2f}x [{c['per_core_of_medians']:.2f}x]")
    write_artifact("mojo_mount", rows, {
        "duration": f"{args.secs}s", "connections": str(args.conns),
        "rounds": str(args.rounds), "blocking_threads": str(args.threads),
        "corpus": "4096x256 f32, LCG seed 20260910",
    }, extra={"comparisons": comparisons})
    return 0


def compare(rows, sels):
    """Mojo over Python per selectivity, with the method written down.

    The headline is a within-round ratio -- the two arms of a round run back
    to back on the same machine state, which is the stable signal
    bench_record.py's docstring describes -- and its median across rounds.
    `per_core_of_medians` divides the artifact's own `medians` block
    instead (median rps over median cores, per arm), which is what a reader
    computes from that block; the 2026-09-10 run gave 1.65x one way and 1.61x
    the other at sel=25, so both are carried. Its commit message mixed them --
    throughput as a ratio of medians (4.43x), per core by round (1.65x) -- so
    throughput is carried both ways too (4.52x by round).
    """
    import statistics
    by = {(r["round"], r["name"]): r for r in rows}
    out = {}
    for sel in sels:
        thru, per, py_pc, mo_pc = [], [], [], []
        for rnd in sorted({r["round"] for r in rows}):
            py = by.get((rnd, f"python(sel={sel})"))
            mo = by.get((rnd, f"mojo(sel={sel})"))
            if not py or not mo:
                continue
            if py["rps"] and mo["rps"]:
                thru.append(mo["rps"] / py["rps"])
            if py["rps_per_core"] and mo["rps_per_core"]:
                per.append(mo["rps_per_core"] / py["rps_per_core"])
            if py["rps"] and py["cores"]:
                py_pc.append((py["rps"], py["cores"]))
            if mo["rps"] and mo["cores"]:
                mo_pc.append((mo["rps"], mo["cores"]))

        def of_medians(pairs):
            return (statistics.median(p[0] for p in pairs)
                    / statistics.median(p[1] for p in pairs))

        out[str(sel)] = {
            "throughput": round(statistics.median(thru), 3) if thru else None,
            "throughput_of_medians": round(
                statistics.median(p[0] for p in mo_pc)
                / statistics.median(p[0] for p in py_pc), 3)
            if py_pc and mo_pc else None,
            "per_core": round(statistics.median(per), 3) if per else None,
            "per_core_of_medians": round(of_medians(mo_pc) / of_medians(py_pc), 3)
            if py_pc and mo_pc else None,
            "rounds": len(per),
        }
    return {
        "definition": "by_sel[sel].throughput and .per_core: median across "
        "rounds of mojo / python within the round (the headline); "
        ".throughput_of_medians and .per_core_of_medians: mojo's median rps "
        "(over its median cores) against python's, the ratios the medians "
        "block gives",
        "by_sel": out,
    }


if __name__ == "__main__":
    sys.exit(main())
