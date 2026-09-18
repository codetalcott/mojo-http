#!/usr/bin/env python3
"""One loop, N workers or N loops on threads: which serves blobs on one small CPU.

The question DECISIONS D36 answers by measurement, for the blobs deploy: a
Fly shared-cpu-1x machine is ONE virtual CPU at 256 MB, billed by the
machine, so what a mode costs in CPU and memory is the whole question and
parallelism buys little. D35 measured workers against threads on a many-core
Mac and Linux box and found parity; this measures the demo itself, in its
own deploy image, on the budget it will have.

Each arm is a fresh container of the SAME image with `--cpus` and
`--memory` set as the machine's (`--cpus 1 --memory 256m` by default) and
one of:

    loop         the host's default: one event loop, the producer beside it
    workers=N    M0_WORKERS=N: prefork, a supervisor, accept sharing
    threads=N    M0_THREADS=N: N loops on N threads of one process

The load is the demo's: V viewers each holding `/events` (every step's
frame fanned out to all of them), plus one keep-alive connection timing a
trivial `/now` every 50 ms. The client runs in a container on the same
docker network, so the published port's forwarding is not what is measured,
and it is not CPU-limited. Over a measured window after a warm-up:

  * cores: the server container's cgroup CPU over the window (all of its
    processes and threads), and the time the cgroup was throttled;
  * RSS: VmRSS summed over the server's processes, mid-window;
  * delivery: the fraction of (viewer, frame) pairs that arrived, over the
    frames any viewer saw -- a mode that sheds frames under its budget
    shows here, not in its CPU;
  * fan-out spread: per frame, last arrival minus first across viewers
    (p50/p99) -- how long the slowest tab waits behind the fastest;
  * `/now` p50/p99/max: what a request waits behind the fan-out;
  * the producer's own step time from `/stats`.

    python3 scripts/bench_blobs_modes.py --build                    # local arch
    python3 scripts/bench_blobs_modes.py --image m0-blobs:dev --viewers 100,400

Writes `bench/results/blobs-modes-*.json` through bench_record. Absolute
figures move with the machine; the within-round ratios between arms are the
signal.
"""

import argparse
import json
import selectors
import socket
import statistics
import subprocess
import sys
import threading
import time
import traceback
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("bench_blobs_modes FAIL: %s: %r" % (PHASE, exc))


sys.excepthook = _stamped


def fail(msg):
    sys.exit(f"bench_blobs_modes FAIL: {PHASE}: {msg}")


# --- the client, run inside a container on the server's network ------------


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(q * (len(s) - 1) + 0.5))]


def client(host, port, viewers, warm, secs):
    """Hold `viewers` streams and time `/now`; print one JSON line at the end.

    Prints `START` and `END` lines at the window's edges, so the driver can
    read the server's cgroup at the same moments.
    """
    phase("opening the streams")
    sel = selectors.DefaultSelector()
    bufs = {}
    arrivals = {}  # id -> list of arrival times within the window
    got = [0] * viewers
    for i in range(viewers):
        s = socket.create_connection((host, port), timeout=10)
        s.sendall(b"GET /events HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n\r\n")
        s.setblocking(False)
        sel.register(s, selectors.EVENT_READ, i)
        bufs[i] = b""
    now_lat = []
    stop = threading.Event()
    window = {"on": False}

    def time_now():
        c = socket.create_connection((host, port), timeout=10)
        req = b"GET /now HTTP/1.1\r\nHost: x\r\n\r\n"
        while not stop.is_set():
            t0 = time.perf_counter()
            c.sendall(req)
            buf = b""
            while b"\r\n\r\n" not in buf or not buf.endswith(b"}"):
                chunk = c.recv(4096)
                if not chunk:
                    return
                buf += chunk
            if window["on"]:
                now_lat.append((time.perf_counter() - t0) * 1e6)
            time.sleep(0.05)
        c.close()

    timer = threading.Thread(target=time_now, daemon=True)
    timer.start()

    phase("the window")
    t_start = time.perf_counter() + warm
    t_end = t_start + secs
    started = False
    while True:
        now = time.perf_counter()
        if not started and now >= t_start:
            window["on"] = True
            started = True
            print("START", flush=True)
        if now >= t_end:
            break
        for key, _ in sel.select(timeout=0.05):
            i = key.data
            try:
                chunk = key.fileobj.recv(262144)
            except BlockingIOError:
                continue
            if not chunk:
                sel.unregister(key.fileobj)
                continue
            t = time.perf_counter()
            buf = bufs[i] + chunk
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                pos = block.find(b"\nid: ")
                if pos < 0 and block.startswith(b"id: "):
                    pos = -1
                elif pos < 0:
                    continue
                end = block.find(b"\n", pos + 1)
                ident = int(block[pos + 5: end if end > 0 else None])
                if window["on"]:
                    arrivals.setdefault(ident, []).append(t)
                    got[i] += 1
            bufs[i] = buf
    window["on"] = False
    print("END", flush=True)
    stop.set()
    c = socket.create_connection((host, port), timeout=10)
    c.sendall(b"GET /stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    raw = b""
    while True:
        chunk = c.recv(65536)
        if not chunk:
            break
        raw += chunk
    c.close()
    producer = json.loads(raw.split(b"\r\n\r\n", 1)[1])

    ids = sorted(arrivals)
    # The window's first and last frames are cut by its edges: count only
    # the frames every viewer had the chance to see whole.
    inner = ids[1:-1] if len(ids) > 2 else ids
    pairs = sum(len(arrivals[k]) for k in inner)
    spread = [(max(arrivals[k]) - min(arrivals[k])) * 1e3 for k in inner if arrivals[k]]
    out = {
        "frames": len(inner),
        "delivered": round(pairs / (len(inner) * viewers), 4) if inner else 0.0,
        "spread_p50_ms": round(pct(spread, 0.5) or 0, 2),
        "spread_p99_ms": round(pct(spread, 0.99) or 0, 2),
        "now_p50_us": round(pct(now_lat, 0.5) or 0),
        "now_p99_us": round(pct(now_lat, 0.99) or 0),
        "now_max_us": round(max(now_lat) if now_lat else 0),
        "now_samples": len(now_lat),
        "viewers_min_frames": min(got),
        "step_us": producer["step_us"],
        "step_us_max": producer["step_us_max"],
        "over_budget": producer["over_budget"],
        "refused": producer["refused"],
    }
    print(json.dumps(out), flush=True)


# --- the driver ------------------------------------------------------------------


def run(*argv, check=True, timeout=900):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd=REPO)
    if check and p.returncode != 0:
        fail(f"`{' '.join(argv)}` exited {p.returncode}:\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}")
    return p


def cgroup_cpu(name):
    """(usage_usec, throttled_usec) of the container's cgroup."""
    out = run("docker", "exec", "-u", "0", name, "cat", "/sys/fs/cgroup/cpu.stat").stdout
    stat = dict(line.split() for line in out.splitlines() if line.strip())
    return int(stat["usage_usec"]), int(stat.get("throttled_usec", 0))


def rss_kb(name):
    out = run("docker", "exec", "-u", "0", name, "sh", "-c",
              "for d in /proc/[0-9]*; do "
              "[ \"$(tr '\\0' ' ' < $d/cmdline 2>/dev/null)\" = '/app/server ' ] || continue; "
              "sed -n 's/^VmRSS:[[:space:]]*\\([0-9]*\\) kB/\\1/p' $d/status; done").stdout
    return sum(int(x) for x in out.split() if x.isdigit())


def arm_env(arm, n):
    if arm == "loop":
        return []
    kind = "M0_WORKERS" if arm.startswith("workers") else "M0_THREADS"
    return ["-e", f"{kind}={n}"]


def run_arm(args, net, image, arm, viewers, rnd):
    name = f"m0-bench-blobs-{uuid.uuid4().hex[:8]}"
    phase(f"r{rnd} {arm} v{viewers}: start")
    run("docker", "run", "-d", "--name", name, "--network", net,
        "--cpus", str(args.cpus), "--memory", args.memory,
        *arm_env(arm, args.n), image)
    try:
        # The script travels on stdin, not a bind mount: a daemon in a VM
        # (colima) sees only the directories it shares, and a worktree under
        # /tmp is not one of them.
        client_argv = [
            "docker", "run", "--rm", "-i", "--network", net, args.client_image,
            "python3", "-", "client", "--host", name,
            "--viewers", str(viewers), "--warm", str(args.warm), "--secs", str(args.secs),
        ]
        # Wait for health from inside the network.
        deadline = time.monotonic() + 30
        while run("docker", "exec", name, "sh", "-c", "true", check=False).returncode != 0:
            if time.monotonic() > deadline:
                fail("the server container never came up")
            time.sleep(0.2)
        time.sleep(1.0)
        phase(f"r{rnd} {arm} v{viewers}: measure")
        proc = subprocess.Popen(client_argv, stdin=open(Path(__file__).resolve()),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        cpu0 = cpu1 = None
        t0 = t1 = None
        rss = None
        result = None
        for line in proc.stdout:
            line = line.strip()
            if line == "START":
                cpu0, t0 = cgroup_cpu(name), time.monotonic()
                threading.Timer(args.secs / 2, lambda: rss_box.append(rss_kb(name))).start()
            elif line == "END":
                cpu1, t1 = cgroup_cpu(name), time.monotonic()
            elif line.startswith("{"):
                result = json.loads(line)
        proc.wait(timeout=60)
        if proc.returncode != 0 or result is None or cpu0 is None or cpu1 is None:
            fail(f"the client failed: {proc.stderr.read()[-2000:]}\n" + run("docker", "logs", name, check=False).stderr[-2000:])
        rss = rss_box.pop() if rss_box else rss_kb(name)
        wall = t1 - t0
        cores = (cpu1[0] - cpu0[0]) / 1e6 / wall
        throttled = (cpu1[1] - cpu0[1]) / 1e6 / wall
        row = {
            "round": rnd, "name": f"{arm} v{viewers}", "arm": arm, "viewers": viewers,
            "cores": round(cores, 3), "throttled_frac": round(throttled, 3),
            "rss_kb_summed": rss, **result,
        }
        row["cores_per_100_viewers"] = round(cores / viewers * 100, 4)
        return row
    finally:
        run("docker", "rm", "-f", name, check=False)


rss_box = []


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "client":
        ap = argparse.ArgumentParser()
        ap.add_argument("cmd")
        ap.add_argument("--host", required=True)
        ap.add_argument("--port", type=int, default=8080)
        ap.add_argument("--viewers", type=int, required=True)
        ap.add_argument("--warm", type=float, default=3)
        ap.add_argument("--secs", type=float, default=20)
        a = ap.parse_args()
        client(a.host, a.port, a.viewers, a.warm, a.secs)
        return 0

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--image", help="an image built from deploy/mojo/Dockerfile with APP=blobs")
    src.add_argument("--build", action="store_true", help="build it first, for the daemon's arch")
    ap.add_argument("--n", type=int, default=2, help="workers, and loops")
    ap.add_argument("--viewers", default="100,400")
    ap.add_argument("--cpus", type=float, default=1.0)
    ap.add_argument("--memory", default="256m")
    ap.add_argument("--secs", type=float, default=20)
    ap.add_argument("--warm", type=float, default=3)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--gap", type=float, default=2.0)
    ap.add_argument("--client-image", default="python:3.13-slim")
    ap.add_argument("--name", default="blobs_modes")
    ap.add_argument("--no-artifact", action="store_true")
    args = ap.parse_args()

    phase("setup")
    arch = run("docker", "info", "--format", "{{.Architecture}}").stdout.strip()
    image = args.image
    if args.build:
        cpu = "x86-64-v2" if arch in ("x86_64", "amd64") else "generic"
        image = f"m0-bench-blobs:{uuid.uuid4().hex[:8]}"
        run("docker", "build", "-q", "-f", "deploy/mojo/Dockerfile", "--build-arg", "APP=blobs",
            "--build-arg", f"TARGET_CPU={cpu}", "-t", image, ".", timeout=1800)
    facts = json.loads(run("docker", "run", "--rm", "--entrypoint", "cat", image, "/app/about.json").stdout)
    # Where the server actually ran. The artifact's `environment` describes
    # the machine running THIS driver, which under colima is a Mac while the
    # measured server is in a Linux VM with its own core count.
    daemon = json.loads(run("docker", "info", "--format",
                            '{"os":{{json .OperatingSystem}},"kernel":{{json .KernelVersion}},'
                            '"arch":{{json .Architecture}},"cpus":{{.NCPU}},"memory_bytes":{{.MemTotal}}}').stdout)
    net = f"m0-bench-{uuid.uuid4().hex[:8]}"
    run("docker", "network", "create", net)
    arms = ["loop", f"workers={args.n}", f"threads={args.n}"]
    rows = []
    try:
        for rnd in range(1, args.rounds + 1):
            for v in [int(x) for x in args.viewers.split(",")]:
                for arm in arms:
                    r = run_arm(args, net, image, arm, v, rnd)
                    rows.append(r)
                    print(f"  r{rnd} {r['name']:<16} cores={r['cores']:<6} thr={r['throttled_frac']:<5} "
                          f"rss={r['rss_kb_summed']}kB deliv={r['delivered']} "
                          f"spread p99={r['spread_p99_ms']}ms now p99={r['now_p99_us']}us "
                          f"max={r['now_max_us']}us", flush=True)
                    time.sleep(args.gap)
    finally:
        run("docker", "network", "rm", net, check=False)
        if args.build:
            run("docker", "rmi", "-f", image, check=False)

    phase("the comparison")
    comparisons = {"definition": "per (viewers): median over rounds of each arm's figure over the loop arm's, same round"}
    for v in sorted({r["viewers"] for r in rows}):
        for arm in arms[1:]:
            ratios = {"cores": [], "rss": [], "now_p99": []}
            for rnd in range(1, args.rounds + 1):
                base = next(r for r in rows if r["round"] == rnd and r["viewers"] == v and r["arm"] == "loop")
                other = next(r for r in rows if r["round"] == rnd and r["viewers"] == v and r["arm"] == arm)
                ratios["cores"].append(other["cores"] / base["cores"] if base["cores"] else 0)
                ratios["rss"].append(other["rss_kb_summed"] / base["rss_kb_summed"])
                ratios["now_p99"].append(other["now_p99_us"] / base["now_p99_us"] if base["now_p99_us"] else 0)
            comparisons[f"{arm} / loop, v{v}"] = {k: round(statistics.median(x), 2) for k, x in ratios.items()}
    for k, c in comparisons.items():
        if k != "definition":
            print(f"  {k:<24} cores {c['cores']}x  rss {c['rss']}x  now p99 {c['now_p99']}x")
    if args.no_artifact:
        return 0
    from bench_record import write_artifact  # noqa: E402
    write_artifact(args.name, rows, {
        "n": str(args.n), "viewers": args.viewers, "cpus": str(args.cpus), "memory": args.memory,
        "window": f"{args.secs}s after {args.warm}s", "rounds": str(args.rounds),
        "subject": "apps/blobs in deploy/mojo/Dockerfile's image; /events held by V viewers, /now every 50 ms",
        "image": {k: facts.get(k) for k in ("version", "target_cpu", "arch", "image_bytes", "app_bytes")},
        "daemon": daemon,
    }, extra={"comparisons": comparisons})
    return 0


if __name__ == "__main__":
    sys.exit(main())
