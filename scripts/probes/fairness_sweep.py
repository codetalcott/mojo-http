#!/usr/bin/env python3
"""Which load makes the keep rule's old shape starve a waiter, here?

The keep rule (SPEC E34; docs/notes/a-slice-keeps-the-gil.md) stops a pool
thread dropping the GIL between the jobs of its slice. With it off
(`M0_POOL_TURN_KEEP=0`) a parked waiter starves on the 4-vCPU KVM guest
that found it, every run, and on GitHub's Linux runner it did not: the
same probe answered that shape in order there
(docs/notes/fairness-judged-by-order.md). The starvation is a race the
parked waiter has to LOSE -- to the thread that just dropped the GIL and
takes it straight back -- so it belongs to the machine as much as to the
code, and a shape that starves one machine may not starve another.

This sweeps shapes and runs both arms of each: the keep rule on, which
must stay in order, and off, which a useful shape must put out of order.
The levers are the pool's threads, the probe's connections, the view's
length, the CPUs the server may run on (`taskset`; the client gets the
rest) and busy loops beside it. Each run is `scripts/pool_fairness_probe.py`
against a fresh `bin/m0serve`, its figures read from the probe's
machine lines; the probe's own verdict is not the sweep's, so its exit
status is ignored.

    python3 scripts/probes/fairness_sweep.py                  # every shape, 2 rounds
    python3 scripts/probes/fairness_sweep.py --shapes base,cpu1 --rounds 3
    python3 scripts/probes/fairness_sweep.py --list

One JSON line per run on stdout, then a table per shape: the long waits
(requests passed over by more than 100 later answers) and the most
passed over, for each arm, across rounds. A shape is USEFUL when every
keep-off run is out of order and every keep-on run in order, by the
probe's own bounds (at most 5 long waits, none past 1000).
"""
import json
import os
import platform
import re
import signal
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROBE = os.path.join(REPO, "scripts", "pool_fairness_probe.py")

# name: threads, conns, busy ms, server CPUs (None: all), hogs, hog CPUs
SHAPES = {
    "base":      dict(threads=4, conns=16, busy="0.3"),
    "c64":       dict(threads=4, conns=64, busy="0.3"),
    "b0.05":     dict(threads=4, conns=16, busy="0.05"),
    "b1":        dict(threads=4, conns=16, busy="1.0"),
    "t2":        dict(threads=2, conns=16, busy="0.3"),
    "t8":        dict(threads=8, conns=32, busy="0.3"),
    "cpu1":      dict(threads=4, conns=16, busy="0.3", cpus="0"),
    "cpu2":      dict(threads=4, conns=16, busy="0.3", cpus="0,1"),
    "cpu1-t8":   dict(threads=8, conns=32, busy="0.3", cpus="0"),
    "hog4":      dict(threads=4, conns=16, busy="0.3", hogs=4),
    "hog8":      dict(threads=4, conns=16, busy="0.3", hogs=8),
    "cpu2-hog2": dict(threads=4, conns=16, busy="0.3", cpus="0,1", hogs=2, hog_cpus="0,1"),
    # The second sweep, around the base shape: the view's length (jobs per
    # 1 ms slice), the waiters (threads) and the queue behind them.
    "b0.15":     dict(threads=4, conns=16, busy="0.15"),
    "b0.2":      dict(threads=4, conns=16, busy="0.2"),
    "b0.45":     dict(threads=4, conns=16, busy="0.45"),
    "b0.6":      dict(threads=4, conns=16, busy="0.6"),
    "t3":        dict(threads=3, conns=16, busy="0.3"),
    "t5":        dict(threads=5, conns=20, busy="0.3"),
    "t6":        dict(threads=6, conns=24, busy="0.3"),
    "t3-b0.2":   dict(threads=3, conns=16, busy="0.2"),
    "t5-b0.45":  dict(threads=5, conns=20, busy="0.45"),
    "c8":        dict(threads=4, conns=8, busy="0.3"),
    "c32":       dict(threads=4, conns=32, busy="0.3"),
}

LONG_WAITS_ALLOWED = 5
MOST_PASSED_OVER = 1000


def arg(name, default):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


def complement(cpus):
    n = os.cpu_count() or 1
    taken = {int(c) for c in cpus.split(",")}
    rest = [str(c) for c in range(n) if c not in taken]
    return ",".join(rest) if rest else None


def machine():
    model = ""
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    model = line.split(":", 1)[1].strip()
                    break
    except OSError:
        model = platform.processor()
    return {"cpus": os.cpu_count(), "cpu": model, "kernel": platform.release(),
            "system": platform.system(), "python": platform.python_version()}


def run_arm(binary, port, shape, keep, seconds):
    env = dict(os.environ)
    env.pop("M0_POOL_TURN_KEEP", None)
    if not keep:
        env["M0_POOL_TURN_KEEP"] = "0"
    srv = [binary, "bareapp.wsgi:application", "--app-dir", "apps/wsgi_bare",
           "--port", str(port), "--blocking-threads", str(shape["threads"])]
    cli = [sys.executable, PROBE, str(port), "--conns", str(shape["conns"]),
           "--busy-ms", shape["busy"], "--seconds", str(seconds)]
    cpus = shape.get("cpus")
    if cpus:
        srv = ["taskset", "-c", cpus] + srv
        rest = complement(cpus)
        if rest:
            cli = ["taskset", "-c", rest] + cli
    hogs = []
    server = subprocess.Popen(srv, cwd=REPO, env=env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        for _ in range(shape.get("hogs", 0)):
            hog = ["sh", "-c", "while :; do :; done"]
            if shape.get("hog_cpus"):
                hog = ["taskset", "-c", shape["hog_cpus"]] + hog
            hogs.append(subprocess.Popen(hog, start_new_session=True))
        out = subprocess.run(cli, cwd=REPO, capture_output=True, text=True,
                             timeout=seconds + 120).stdout
    finally:
        for h in hogs:
            os.killpg(h.pid, signal.SIGKILL)
            h.wait()
        server.send_signal(signal.SIGTERM)
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait()
    fig = {}
    for key in ("p99_ms", "max_ms", "long_waits", "most_passed_over"):
        m = re.search(r"^%s (\S+)$" % key, out, re.M)
        fig[key] = float(m.group(1)) if m else None
    m = re.search(r"n=(\d+) errors=(\d+)", out)
    fig["n"], fig["errors"] = (int(m.group(1)), int(m.group(2))) if m else (None, None)
    if fig["long_waits"] is None:
        fig["probe_tail"] = out[-400:]
    return fig


def in_order(fig):
    return (fig["long_waits"] is not None and fig["long_waits"] <= LONG_WAITS_ALLOWED
            and fig["most_passed_over"] <= MOST_PASSED_OVER)


def span(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return "-"
    lo, hi = min(vals), max(vals)
    return ("%g" % lo) if lo == hi else ("%g-%g" % (lo, hi))


def main():
    if "--list" in sys.argv:
        for name, shape in SHAPES.items():
            print(name, shape)
        return 0
    binary = os.path.join(REPO, arg("--binary", "bin/m0serve"))
    rounds = int(arg("--rounds", "2"))
    seconds = float(arg("--seconds", "10"))
    port = int(arg("--port", "8397"))
    names = arg("--shapes", ",".join(SHAPES)).split(",")
    for name in names:
        if name not in SHAPES:
            print("fairness_sweep: unknown shape %r (--list)" % name)
            return 2
    tag = arg("--tag", "")
    host = machine()
    print(json.dumps({"machine": host, "tag": tag}), flush=True)
    results = {}
    for rnd in range(1, rounds + 1):
        for name in names:
            for keep in (True, False):
                fig = run_arm(binary, port, SHAPES[name], keep, seconds)
                fig.update({"shape": name, "keep": keep, "round": rnd, "tag": tag})
                results.setdefault((name, keep), []).append(fig)
                print(json.dumps(fig), flush=True)
    print()
    print("machine: %(cpu)s, %(cpus)s CPUs, %(system)s %(kernel)s, Python %(python)s" % host)
    print()
    print("| shape | keep on: long waits | most | in order | keep off: long waits | most | out of order | useful |")
    print("|---|---|---|---|---|---|---|---|")
    for name in names:
        on, off = results[(name, True)], results[(name, False)]
        on_ok = sum(1 for f in on if in_order(f))
        off_ok = sum(1 for f in off if f["long_waits"] is not None and not in_order(f))
        useful = on_ok == len(on) and off_ok == len(off)
        print("| %s | %s | %s | %d/%d | %s | %s | %d/%d | %s |" % (
            name, span(f["long_waits"] for f in on), span(f["most_passed_over"] for f in on),
            on_ok, len(on), span(f["long_waits"] for f in off),
            span(f["most_passed_over"] for f in off), off_ok, len(off),
            "YES" if useful else "no"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
