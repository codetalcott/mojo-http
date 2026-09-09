#!/usr/bin/env python3
"""Do the benchmark page's conclusions hold on Linux? Run it and find out.

    uv run poe bench-linux-conclusions          # the m0lin container
    ROUNDS=1 uv run poe bench-linux-conclusions # a quick shape check

Every artifact docs/BENCHMARKS.md renders is macOS arm64. Measured
2026-09-08 (docs/notes/the-conclusions-on-linux.md), TWO of its four
headline conclusions invert on Linux -- both of the "No" answers -- because
a cross-thread handoff costs less on epoll and futex than on kqueue, and
the handoff is what m0serve's two-thread shape pays for its isolation. This
re-runs that comparison so the answer can be refreshed rather than
remembered.

**Not in CI, and it must not be.** The differences that matter are narrow
(0.98x -> 1.08x), and a shared 4-core runner cannot resolve a ten-percent
ratio shift -- the same reason `stress-pool` is a pre-release step. A gate
that cannot see what it watches for is worse than none, because it reads as
coverage. This is a pre-release step (docs/RELEASING.md).

What it does NOT claim: absolutes. This runs in a VM on a Mac, and the
server shares the VM's cpus with the load generator. Ratios within one run
are the signal, every comparator is re-measured beside every arm, and the
per-arm spread is printed so a contaminated run is visible rather than
averaged away.
"""
import argparse, json, os, pathlib, shutil, statistics as st, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTAINER = os.environ.get("M0_LINUX_CONTAINER", "m0lin")
IMAGE = "ghcr.io/astral-sh/uv:python3.13-bookworm"
# The peaks this measures, so a reader can size a box for it: the isolation
# rows want ~3.6 cores of server, the load generator ~1-2 more. Eight
# dedicated vcpus is what produced 0.8-2.1% spreads; four covers the
# one-worker rows, which are the two that inverted.
KINDS = {
    "asgi":  ("asgi_wrk_hello", {"client": "wrk -t2 -c16 -d8s, browser headers",
                                 "app": "apps/asgi_bare bareapp.asgi:application /"}),
    "layer": ("layer_split",    {"client": "wrk -t2 -c16 -d10s, browser headers"}),
    "iso":   ("mixed_workload", {"client": "wrk -t2 -c16 -d10s, browser headers",
                                 "hold_ms": "200"}),
}

def run(*argv, **kw):
    return subprocess.run(argv, text=True, capture_output=True, **kw)

def dexec(*argv, env=None, check=True):
    pre = ["docker", "exec"]
    for k, v in (env or {}).items():
        pre += ["-e", f"{k}={v}"]
    r = run(*pre, CONTAINER, *argv)
    if check and r.returncode != 0:
        sys.exit(f"bench-linux-conclusions: `{' '.join(argv[:3])}` failed:\n{r.stdout}\n{r.stderr}")
    return r

def ensure_container():
    if run("docker", "start", CONTAINER).returncode == 0:
        return False
    print(f"creating the {CONTAINER} container ({IMAGE})", flush=True)
    r = run("docker", "run", "-d", "--name", CONTAINER, "--platform", "linux/arm64",
            IMAGE, "sleep", "infinity")
    if r.returncode != 0:
        sys.exit(f"could not create {CONTAINER}: {r.stderr}")
    return True

def push_tree():
    """The tree in by tar, NOT a bind mount: a bind-mounted /src was measured
    serving a frozen snapshot after a colima restart, with the container
    reporting itself Up (scripts/probes/linux_setup.sh's header)."""
    tar = subprocess.Popen(
        ["tar", "--exclude=.venv", "--exclude=.git", "--exclude=packages/*/*.mojoc",
         "--exclude=bin/*", "--exclude=.claude", "-cf", "-",
         "packages", "scripts", "apps", "pyproject.toml", "uv.lock"],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    sink = subprocess.Popen(["docker", "exec", "-i", CONTAINER, "bash", "-c",
                             "mkdir -p /src && cd /src && tar -xf -"],
                            stdin=tar.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tar.stdout.close(); sink.wait(); tar.wait()

def stamp():
    r = run("bash", str(ROOT / "scripts/probes/source_stamp.sh"), cwd=ROOT)
    return r.stdout.strip()

def git_sha():
    return run("git", "-C", str(ROOT), "rev-parse", "--short", "HEAD").stdout.strip()

def compare(linux_dir):
    """The whole point: each macOS conclusion, holds or inverts."""
    def newest(kind):
        f = sorted((ROOT / "bench/results").glob(f"{kind}-*.json"))
        return json.load(open(f[-1]))["medians"] if f else {}
    def lin(kind):
        f = sorted(linux_dir.glob(f"{kind}-linux-*.json"))
        return json.load(open(f[-1]))["medians"] if f else {}
    def r(m, a, b, k="rps"):
        if a in m and b in m and m[b].get(k):
            return m[a][k] / m[b][k]
        return None
    # Both sides key on the ARTIFACT kind, not the bench name the arms use
    # internally: the Linux files are `<kind>-linux-<stamp>.json`, so passing
    # "layer" globbed `layer-linux-*` and matched nothing. Every row then read
    # "no data" and the task still exited 0 -- a comparison that measured
    # nothing and said so quietly, which `_no_data_is_a_failure` below now
    # refuses.
    rows = [
        ("WSGI vs Granian, 1w 1bt (rps)", "layer-split",
         "m0serve+bare w1 bt1", "granian+bare w1", "rps"),
        ("WSGI vs Granian, per core", "layer-split",
         "m0serve+bare w1 bt1", "granian+bare w1", "rps_per_core"),
        ("ASGI vs uvicorn+uvloop (rps)", "asgi-wrk-hello",
         "m0serve asgi-executor", "uvicorn uvloop", "rps"),
        ("ASGI vs uvicorn+uvloop, per core", "asgi-wrk-hello",
         "m0serve asgi-executor", "uvicorn uvloop", "rps_per_core"),
        ("ASGI vs uvicorn asyncio (rps)", "asgi-wrk-hello",
         "m0serve asgi-executor", "uvicorn asyncio", "rps"),
    ]
    print("\n" + "=" * 78)
    print("  Each macOS conclusion, on Linux.  >1.0 means m0serve ahead.")
    print("=" * 78)
    print(f"  {'conclusion':<36} {'macOS':>8} {'Linux':>8}   verdict")
    missing = []
    for label, kind, a, b, k in rows:
        m, l = r(newest(kind), a, b, k), r(lin(kind), a, b, k)
        if m is None or l is None:
            print(f"  {label:<36} {'--':>8} {'--':>8}   no data")
            missing.append(label)
            continue
        verdict = "INVERTS" if (m - 1) * (l - 1) < 0 else "holds"
        print(f"  {label:<36} {m:>8.2f} {l:>8.2f}   {verdict}")
    print("\n  Absolutes are NOT comparable across the two columns -- a VM on a Mac,")
    print("  server and client sharing its cpus. The ratios are the claim.")
    return missing

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=int(os.environ.get("ROUNDS", "3")))
    ap.add_argument("--keep", action="store_true", help="leave the container running")
    a = ap.parse_args()
    if run("docker", "info").returncode != 0:
        sys.exit("bench-linux-conclusions: no docker daemon (start colima, or set DOCKER_HOST)")
    created = ensure_container()
    if created:
        push_tree()
        print("provisioning (apt, uv sync, toolchain) -- several minutes", flush=True)
        dexec("bash", "/src/scripts/probes/linux_setup.sh")
    push_tree()
    s = stamp()
    print(f"syncing at {git_sha()} (source stamp {s})", flush=True)
    dexec("bash", "/src/scripts/probes/linux_sync.sh", "http", "wsgi", "serve",
          env={"M0_SYNC_STAMP": s})
    dexec("bash", "-c", "command -v wrk >/dev/null || (apt-get update -qq && apt-get install -y -qq wrk) >/dev/null 2>&1")
    dexec("bash", "-c", "cd /work && uv sync --group bench >/dev/null 2>&1 || true")
    dexec("bash", "-c", "cd /work && uv run mojo build -I packages/m0-core/ -I packages/m0-http/ "
                        "apps/hello/server.mojo -o /tmp/bench_hello_server >/dev/null 2>&1")
    for f in ("scripts/bench_linux_arms.py",):
        run("docker", "cp", str(ROOT / f), f"{CONTAINER}:/work/{pathlib.Path(f).name}")
    print(f"running {a.rounds} round(s) -- roughly {a.rounds * 6} minutes", flush=True)
    r = dexec("bash", "-c", f"cd /work && ROUNDS={a.rounds} python3 bench_linux_arms.py", check=False)
    print(r.stdout[-2000:] if r.stdout else r.stderr[-2000:])
    if r.returncode != 0:
        sys.exit("bench-linux-conclusions: the arms failed (see above)")
    out = ROOT / "bench/results" / f"linux-{time.strftime('%Y-%m')}"
    out.mkdir(parents=True, exist_ok=True)
    names = dexec("bash", "-c", "cd /work && python3 bench_linux_arms.py --record",
                  env={"BENCH_GIT_SHA": git_sha(), "BENCH_SOURCE_STAMP": s}).stdout.split()
    for p in names:
        base = pathlib.Path(p).name
        kind, _, rest = base.partition("-2")
        run("docker", "cp", f"{CONTAINER}:{p}", str(out / f"{kind}-linux-2{rest}"))
    print(f"\nartifacts in {out.relative_to(ROOT)}/")
    missing = compare(out)
    if not a.keep:
        run("docker", "stop", CONTAINER)
    if missing:
        # The whole task is this table. A run that produced artifacts and then
        # compared none of them is a run that measured nothing, and exiting 0
        # there is how a check becomes decorative -- the first version of this
        # did exactly that, for every row, because the globs disagreed.
        sys.exit("bench-linux-conclusions: no comparison for "
                 + ", ".join(missing)
                 + " -- artifacts were recorded but the table is empty, so nothing "
                   "was actually compared")

if __name__ == "__main__":
    main()
