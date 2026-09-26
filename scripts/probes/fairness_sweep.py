#!/usr/bin/env python3
"""Which load makes the keep rule's old shape starve a waiter, here?

The keep rule (SPEC E34; docs/notes/a-slice-keeps-the-gil.md) stops a pool
thread dropping the GIL between the jobs of its slice. With it off
(`M0_POOL_TURN_KEEP=0`) each drop sends the waiter it woke to the back of
the queue, and whether that starves anyone depends on how many jobs a 1 ms
slice holds against how many threads wait: on a request's share of the
GIL, the view plus the machine's own cost. This is the instrument that
found it. The probe's first load starved some of GitHub's runners and not
others, and the load the probe runs now starves all of them
(docs/notes/fairness-judged-by-order.md).

This sweeps shapes and runs two arms of each: the rules as shipped, which
must stay in order, and the keep rule off, which a useful shape must put
out of order; `--convoy` adds the turn off (SPEC E11's arm), for a shape
meant to carry the whole probe.
The levers are the pool's threads, the probe's connections, the view's
length, the CPUs the server may run on (`taskset`; the client gets the
rest) and busy loops beside it. Each run is `scripts/pool_fairness_probe.py`
against a fresh `bin/m0serve`, its figures read from the probe's
machine lines; the probe's own verdict is not the sweep's, so its exit
status is ignored.

    uv run python scripts/probes/fairness_sweep.py            # every shape, 2 rounds
    uv run python scripts/probes/fairness_sweep.py --shapes base,t5 --rounds 3
    uv run python scripts/probes/fairness_sweep.py --list

`uv run`, because the server takes the interpreter on PATH: outside the
venv it serves on the system's, and the machine line says which it was.

One JSON line per run on stdout, then a table per shape: the long waits
(requests passed over by more than 100 later answers) and the most
passed over, for each arm, across rounds. A shape is USEFUL when every
run of the rules as shipped is in order and every run of the other arms
out of order, by the probe's own bounds (at most 5 long waits, none past
1000).
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
    # The third, from what the first two showed: with the keep rule off each
    # drop inside a slice rotates the waiters by one, so who starves is
    # decided by the jobs a slice holds (k) against the waiters (threads -
    # 1), and a 0.3 ms view puts k on the 3/4 boundary, where each machine's
    # own overhead picks the side. A view near 0.65 ms is k = 2 anywhere.
    "t3-b0.55":  dict(threads=3, conns=16, busy="0.55"),
    "t3-b0.65":  dict(threads=3, conns=16, busy="0.65"),
    "t3-b0.75":  dict(threads=3, conns=16, busy="0.75"),
    "t5-b0.65":  dict(threads=5, conns=20, busy="0.65"),
    "b0.65":     dict(threads=4, conns=16, busy="0.65"),
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


def server_python(binary):
    """The interpreter the SERVER embeds, from its own doctor.

    The binary resolves libpython from the python3 on PATH, so a sweep
    started outside the venv serves on the system's interpreter, whatever
    this script runs on: the first sweeps here ran 3.11 where CI runs 3.13.
    """
    try:
        out = subprocess.run([binary, "--doctor"], cwd=REPO, capture_output=True,
                             text=True, timeout=60).stdout
        return json.loads(out.strip().splitlines()[-1])["python"]["version"]
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        return "unknown"


def machine(binary):
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
            "system": platform.system(), "python": server_python(binary)}


# The arms: the rules as shipped, which must answer in order; the keep rule
# off, which a useful shape must put out of order; with --convoy, the turn
# off as well (SPEC E11's arm), for a shape meant to carry the whole probe.
ARMS = [("on", {}), ("keep off", {"M0_POOL_TURN_KEEP": "0"})]
CONVOY_ARM = ("turn off", {"M0_POOL_TURN": "0"})


def run_arm(binary, port, shape, knobs, seconds):
    env = dict(os.environ)
    for name in ("M0_POOL_TURN", "M0_POOL_TURN_KEEP"):
        env.pop(name, None)
    env.update(knobs)
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
    arms = ARMS + ([CONVOY_ARM] if "--convoy" in sys.argv else [])
    host = machine(binary)
    print(json.dumps({"machine": host, "tag": tag}), flush=True)
    results = {}
    for rnd in range(1, rounds + 1):
        for name in names:
            for arm, knobs in arms:
                fig = run_arm(binary, port, SHAPES[name], knobs, seconds)
                fig.update({"shape": name, "arm": arm, "round": rnd, "tag": tag})
                results.setdefault((name, arm), []).append(fig)
                print(json.dumps(fig), flush=True)
    print()
    print("machine: %(cpu)s, %(cpus)s CPUs, %(system)s %(kernel)s, the server on Python %(python)s" % host)
    print()
    # A request's share of the GIL, from the rules-on arm: the pool runs one
    # view at a time, so the window over the answers is the time each took,
    # overhead included -- and the 1 ms slice holds ceil(1 / that) of them.
    head = "| shape | ms a request | on: long waits | most | in order |"
    rule = "|---|---|---|---|---|"
    for arm, _ in arms[1:]:
        head += " %s: long waits | most | out of order |" % arm
        rule += "---|---|---|"
    print(head + " useful |")
    print(rule + "---|")
    for name in names:
        on = results[(name, "on")]
        on_ok = sum(1 for f in on if in_order(f))
        useful = on_ok == len(on)
        per = [seconds * 1000.0 / f["n"] for f in on if f["n"]]
        row = "| %s | %s | %s | %s | %d/%d |" % (
            name, span(round(x, 3) for x in per), span(f["long_waits"] for f in on),
            span(f["most_passed_over"] for f in on), on_ok, len(on))
        for arm, _ in arms[1:]:
            off = results[(name, arm)]
            off_ok = sum(1 for f in off if f["long_waits"] is not None and not in_order(f))
            useful = useful and off_ok == len(off)
            row += " %s | %s | %d/%d |" % (
                span(f["long_waits"] for f in off), span(f["most_passed_over"] for f in off),
                off_ok, len(off))
        print(row + " %s |" % ("YES" if useful else "no"))
    return 0

if __name__ == "__main__":
    sys.exit(main())
