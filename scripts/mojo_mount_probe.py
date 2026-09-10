#!/usr/bin/env python3
"""The Mojo mount's reason to exist: no Python in its request path.

Two routes of ONE server are measured under the same load. `/native/*` is
answered by `MojoMount` on a `MojoPool` thread that never attaches to the
interpreter; `/` is answered by the WSGI mount on a handler thread that must
hold the GIL. The load is `/busy`, which spins with the GIL held and never
releases it until it returns -- the shape that convoys a handler pool.

A shared execution mode cannot pass this: if the Mojo mount were served by
anything that takes the interpreter lock, its tail would track the Python
route's rather than staying flat. Both routes are trivial, so any difference
under load is the lock and not the work.

Exits non-zero with the numbers when the claim fails.
"""
import argparse
import http.client
import sys
import threading
import time
import traceback


# Which phase is running, for the crash handler below. The load threads, the
# two samplers and the verdict all go through `http.client`, so a traceback
# out of one says which CALL raised and never which PHASE was being proven.
# apps/asgi_bare/ws_probe.py carries the original of this comment.
PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("mojo_mount_probe FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


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
    ap.add_argument("--min-ratio", type=float, default=3.0)
    ap.add_argument("--budget-ms", type=float, default=25.0)
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

    phase("comparing the two tails")
    if len(mojo) < 20 or len(python) < 20:
        print(f"FAIL: too few samples (mojo {len(mojo)}, python {len(python)})")
        return 1

    m99, p99 = _quantile(mojo, 0.99), _quantile(python, 0.99)
    m50, p50 = _quantile(mojo, 0.50), _quantile(python, 0.50)
    ratio = p99 / m99 if m99 > 0 else float("inf")
    print(
        f"under {args.load_conns} GIL-bound connections: "
        f"mojo mount p50={m50:.2f}ms p99={m99:.2f}ms (n={len(mojo)}), "
        f"python route p50={p50:.2f}ms p99={p99:.2f}ms (n={len(python)}), "
        f"tail ratio {ratio:.1f}x"
    )

    failed = False
    if m99 > args.budget_ms:
        print(f"FAIL: mojo mount p99 {m99:.2f}ms over the {args.budget_ms}ms budget")
        failed = True
    if ratio < args.min_ratio:
        print(
            f"FAIL: tail ratio {ratio:.1f}x under the {args.min_ratio}x floor —"
            " the Mojo mount is tracking the Python route, which is what a"
            " shared execution mode looks like"
        )
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
