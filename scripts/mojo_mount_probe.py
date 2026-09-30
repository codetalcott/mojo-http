#!/usr/bin/env python3
"""The Mojo mount's reason to exist: no Python in its request path.

Two routes of ONE server are measured under the same load. `/native/*` is
answered by `MojoMount` on a `MojoPool` thread that never attaches to the
interpreter; `/` is answered by the WSGI mount on a handler thread that must
hold the GIL. The load is `/busy`, which spins with the GIL held and never
releases it until it returns -- the shape that convoys a handler pool.

A shared execution mode cannot pass this: if the Mojo mount were served by
anything that takes the interpreter lock, its requests would wait as the
Python route's do rather than staying flat. Both routes are trivial, so any
difference under load is the lock and not the work. The verdict reads the
Mojo mount's p90, never its p99, and the comment above it says why.

Exits non-zero with the numbers when the claim fails. Every figure is also
recorded through scripts/emit.py -- a measurement, never the gate.
"""
import argparse
import http.client
import sys
import threading
import time

from emit import emit
from probelib import fail, phase, stamp


# Which phase is running, for the crash handler. The load threads, the two
# samplers and the verdict all go through `http.client`, so a traceback out
# of one says which CALL raised and never which PHASE was being proven.
# apps/asgi_bare/ws_probe.py carries the original of this comment.
stamp("mojo_mount_probe FAIL", fail="FAIL: {msg}")


def _quantile(values, q):
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * q))]


def _sample(port, path, stop, out, gap=0.004):
    conn = http.client.HTTPConnection("localhost", port, timeout=30)
    mine = []
    while not stop.is_set():
        started = time.perf_counter()
        try:
            conn.request("GET", path)
            conn.getresponse().read()
            mine.append((time.perf_counter() - started) * 1000.0)
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
            conn = http.client.HTTPConnection("localhost", port, timeout=30)
        time.sleep(gap)
    out.extend(mine)


def _load(port, path, stop):
    conn = http.client.HTTPConnection("localhost", port, timeout=60)
    while not stop.is_set():
        try:
            conn.request("GET", path)
            conn.getresponse().read()
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
            conn = http.client.HTTPConnection("localhost", port, timeout=60)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--mojo-path", default="/native/probe")
    ap.add_argument("--python-path", default="/")
    ap.add_argument("--load-path", default="/busy?ms=40")
    ap.add_argument("--load-conns", type=int, default=8)
    ap.add_argument("--secs", type=float, default=6.0)
    # Both bounds read the Mojo mount's --quantile; the comment above the
    # verdict says why it is the p90.
    ap.add_argument("--quantile", type=float, default=0.90)
    ap.add_argument("--min-ratio", type=float, default=4.0,
                    help="the Python route's median over the Mojo mount's quantile")
    ap.add_argument("--budget-ms", type=float, default=25.0,
                    help="the Mojo mount's quantile, in ms")
    args = ap.parse_args()

    phase("applying GIL-bound load")
    stop = threading.Event()
    loaders = [
        threading.Thread(target=_load, args=(args.port, args.load_path, stop),
                         daemon=True)
        for _ in range(args.load_conns)
    ]
    for t in loaders:
        t.start()
    time.sleep(1.0)          # let the GIL-bound load actually take hold

    phase("sampling both routes under load")
    mojo, python = [], []
    probes = [
        threading.Thread(target=_sample,
                         args=(args.port, args.mojo_path, stop, mojo),
                         daemon=True),
        threading.Thread(target=_sample,
                         args=(args.port, args.python_path, stop, python),
                         daemon=True),
    ]
    for t in probes:
        t.start()
    time.sleep(args.secs)
    stop.set()
    for t in probes:
        t.join(timeout=30)

    phase("comparing the two routes")
    if len(mojo) < 20 or len(python) < 20:
        fail(f"too few samples (mojo {len(mojo)}, python {len(python)})")

    # The verdict reads the Mojo mount's p90 against the Python route's
    # MEDIAN, and neither p99. Both samplers are closed loops with one
    # request in flight, so a stall of a starved machine delays the one
    # request each has in flight, while a convoy delays every request. A
    # macOS runner's window holds 250-400 Mojo samples and 43-62 Python
    # ones: a p99 there is the third-slowest Mojo request and the slowest
    # Python one, and three stalls own it. Two of three runs on 2026-09-29
    # failed a 25 ms p99 budget that way (36.8 and 31.4 ms at n=278 and 257)
    # with the mount 16x and 13x clear of the Python route, whose own p99 had
    # grown 2-3x in the same window. The p90 is the 25th- to 40th-slowest
    # request, which stalls do not reach and a mount that waits on every
    # request does.
    #
    # Measured on an M4 with client and server clamped to utility QoS under
    # 8 continuous or 12 bursting shell hogs, 4 rounds each, 170-255 Mojo
    # samples a window (stress-asgi's unclamped hogs starve nothing there):
    # the mount's p99 went over 25 ms in 15 of 16 rounds and reached 194 ms,
    # while its p90 stayed at or under 13.5 ms with the Python median at
    # least 8.3x above it. Quiet or starved, `/pid` (the negative arm, a
    # full convoy) never had a p90 under 66 ms nor a ratio over 0.9x, and a
    # mount that takes the GIL once per request (a copy of the demo mount)
    # never a p90 under 29 ms nor a ratio over 2.4x. The p99s are printed
    # and recorded, never judged.
    ql = "p%g" % (args.quantile * 100)
    m50, mq, m99 = (_quantile(mojo, x) for x in (0.50, args.quantile, 0.99))
    p50, p90, p99 = (_quantile(python, x) for x in (0.50, 0.90, 0.99))
    ratio = p50 / mq if mq > 0 else float("inf")
    print(
        f"under {args.load_conns} GIL-bound connections: "
        f"mojo mount p50={m50:.2f}ms {ql}={mq:.2f}ms p99={m99:.2f}ms (n={len(mojo)}), "
        f"python route p50={p50:.2f}ms p90={p90:.2f}ms p99={p99:.2f}ms (n={len(python)}), "
        f"python median / mojo {ql} {ratio:.1f}x"
    )
    task = "smoke-mojo-mount"
    emit(f"mojo_mount.mojo_{ql}_ms", round(mq, 2), unit="ms", limit=args.budget_ms, task=task)
    emit(f"mojo_mount.mojo_{ql}_share_of_python_median", round(mq / p50, 4),
         limit=round(1.0 / args.min_ratio, 4), task=task)
    for name, value in (("mojo_p50", m50), ("mojo_p99", m99), ("python_p50", p50),
                        ("python_p90", p90), ("python_p99", p99)):
        emit(f"mojo_mount.{name}_ms", round(value, 2), unit="ms", task=task)
    emit("mojo_mount.mojo_samples", len(mojo), task=task)

    # Both bounds are reported before the exit, so neither is `fail()`.
    failed = False
    if mq > args.budget_ms:
        print(f"FAIL: mojo mount {ql} {mq:.2f}ms over the {args.budget_ms}ms budget")
        failed = True
    if ratio < args.min_ratio:
        print(
            f"FAIL: the python route's median is {ratio:.1f}x the mojo mount's {ql},"
            f" under the {args.min_ratio}x floor — the Mojo mount waits as the"
            " Python route does, which is what a shared execution mode looks like"
        )
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
