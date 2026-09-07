"""Refuse to benchmark on a machine that is doing something else.

    python3 scripts/bench_guard.py wait            # block until quiet, or exit 1
    python3 scripts/bench_guard.py wait --threshold 50 --samples 3 --timeout 120
    python3 scripts/bench_guard.py --selftest      # prove the guard can fire

Why this exists: on 2026-09-06 a layer-split recording landed its pool
rows 7 % under the rows recorded an hour later, with `apps/hello` and the
Granian comparator unmoved, and `ps` found `contactsd`, `knowledge-agent`
and `AddressBookSourceSync` at a core and a half between them. The
comparator rows exist to let a reader see that kind of contamination
after the fact; this refuses to start the recording while it is
happening, which is cheaper than a discarded twenty-minute run and
safer than one that was not discarded.

The rule is the shape `bench_layer_split.sh`'s TIME_WAIT gate already
has, applied to CPU: sample `ps` a few times a second apart, and any
process that is above the threshold in EVERY sample and is not part of
the benchmark itself is an intruder. "Part of the benchmark" is decided
by process ancestry, not by name -- the guard excludes its own pid and
every ancestor (the bench shell, poe, uv, the terminal), so a hog spelled
`python3` is still a hog. Every sample, not any: `ps`'s `%cpu` is a
decaying average, so a process that is genuinely busy stays above the
line across three samples and a burst that ended does not.

The decision (`intruders`) is a pure function over sampled rows so the
selftest can feed it doctored samples: a sustained hog is reported, a
one-sample spike is not, the benchmark's own process tree is not, and a
quiet machine reports nothing. A guard that cannot fire is decoration.

The threshold is half a core, not the 15 % first proposed: on a ten-core
machine 15 % of one core is 1.5 % of capacity, and `WindowServer` alone
sits at 5–30 % whenever the display is rendering — including the
terminal this guard prints into, which is a feedback loop. The
contamination the guard exists for was a core and a half, and a daemon
doing real work (`mediaanalysisd` at 120 %) is caught at any threshold
above its idle noise.
"""

import os
import subprocess
import sys
import time

DEFAULT_THRESHOLD = 50.0   # percent of one core
DEFAULT_SAMPLES = 3
DEFAULT_INTERVAL = 1.0     # seconds between samples
DEFAULT_TIMEOUT = 120      # seconds to wait for quiet before refusing


def parse_ps(text):
    """`ps -eo %cpu=,pid=,ppid=,comm=` output -> [(cpu, pid, ppid, comm)].

    `comm` may contain spaces (`Google Chrome Helper`), so the line is
    split at most three times and the remainder is the name.
    """
    rows = []
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            cpu, pid, ppid = float(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        rows.append((cpu, pid, ppid, parts[3].strip()))
    return rows


def sample():
    out = subprocess.run(
        ["ps", "-eo", "%cpu=,pid=,ppid=,comm="],
        capture_output=True, text=True, timeout=30,
    ).stdout
    return parse_ps(out)


def own_tree(rows, pid):
    """The pids of `pid` and every ancestor, from one sample's rows."""
    parent = {r[1]: r[2] for r in rows}
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        pid = parent.get(pid, 0)
    return seen


def intruders(samples, exclude, threshold):
    """Processes above `threshold` in EVERY sample, minus `exclude`.

    Returns [(min_cpu, pid, comm)] sorted busiest first. Pure.
    """
    if not samples:
        return []
    busy = None
    names = {}
    for rows in samples:
        here = {}
        for cpu, pid, _ppid, comm in rows:
            if pid in exclude or cpu <= threshold:
                continue
            here[pid] = cpu
            names[pid] = comm
        busy = here if busy is None else {
            pid: min(cpu, busy[pid]) for pid, cpu in here.items() if pid in busy
        }
    return sorted(((cpu, pid, names[pid]) for pid, cpu in busy.items()),
                  reverse=True)


def wait_quiet(threshold, samples, interval, timeout, out=sys.stdout):
    """Block until `samples` consecutive samples show no intruder.

    Prints what it waited for on every busy round; returns True when the
    machine went quiet and False when `timeout` elapsed first.
    """
    started = time.monotonic()
    me = os.getpid()
    while True:
        rows = [sample()]
        exclude = own_tree(rows[0], me)
        for _ in range(samples - 1):
            time.sleep(interval)
            rows.append(sample())
        found = intruders(rows, exclude, threshold)
        if not found:
            return True
        waited = int(time.monotonic() - started)
        desc = ", ".join(f"{os.path.basename(comm)} (pid {pid}) at {cpu:.0f}%" for cpu, pid, comm in found[:5])
        print(f"bench_guard: not quiet after {waited}s — {desc}", file=out, flush=True)
        if waited >= timeout:
            return False
        time.sleep(interval)


def selftest():
    ok = True

    def check(label, cond):
        nonlocal ok
        print(f"  {'caught' if cond else 'MISSED'}          {label}")
        ok &= bool(cond)

    ps = ("  0.3   1     0 launchd\n"
          " 87.5 501   1 contactsd\n"
          " 12.0 777 501 Google Chrome Helper\n"
          "  0.0 900   1 bash\n"
          " 99.0 901 900 python3\n")
    rows = parse_ps(ps)
    check("the ps parser keeps a comm with spaces", ("Google Chrome Helper" in [r[3] for r in rows]))
    check("the ps parser reads five rows", len(rows) == 5)

    quiet = [(0.3, 1, 0, "launchd"), (2.0, 501, 1, "contactsd"), (0.0, 900, 1, "bash")]
    hog = [(0.3, 1, 0, "launchd"), (87.5, 501, 1, "contactsd"), (0.0, 900, 1, "bash")]
    check("(control: a quiet machine reports nothing)",
          intruders([quiet, quiet, quiet], set(), 15.0) == [])
    found = intruders([hog, hog, hog], set(), 15.0)
    check("a process above the line in every sample is an intruder",
          [(pid, comm) for _, pid, comm in found] == [(501, "contactsd")])
    check("a one-sample spike is not",
          intruders([hog, quiet, quiet], set(), 15.0) == [])
    check("the busiest sustained value reported is the MIN across samples",
          intruders([hog, [(0.3, 1, 0, "launchd"), (40.0, 501, 1, "contactsd")], hog], set(), 15.0)[0][0] == 40.0)

    own = [(0.0, 900, 1, "bash"), (99.0, 901, 900, "python3"), (50.0, 902, 901, "wrk")]
    tree = own_tree(own, 902)
    check("ancestry walks from the guard to init", tree == {902, 901, 900, 1})
    check("the benchmark's own process tree is not an intruder",
          intruders([own, own, own], tree, 15.0) == [])
    check("the same tree with nothing excluded IS (the exclusion is doing the work)",
          len(intruders([own, own, own], set(), 15.0)) == 2)

    live = sample()
    check("a live sample lists this process", os.getpid() in {r[1] for r in live})

    # The wait must be able to return False: a threshold below any process's
    # usage plus a zero timeout refuses on the first busy round.
    import io
    sink = io.StringIO()
    refused = not wait_quiet(threshold=-1.0, samples=1, interval=0, timeout=0, out=sink)
    check("`wait` refuses when the machine never goes quiet", refused and "not quiet" in sink.getvalue())
    check("`wait` passes a threshold nothing can reach",
          wait_quiet(threshold=1e9, samples=1, interval=0, timeout=0, out=sink))

    print("bench_guard selftest: " + ("PASS" if ok else "FAIL"))
    return ok


def main(argv):
    if "--selftest" in argv:
        return 0 if selftest() else 1
    if not argv or argv[0] != "wait":
        print(__doc__)
        return 2
    opts = {"--threshold": DEFAULT_THRESHOLD, "--samples": DEFAULT_SAMPLES,
            "--interval": DEFAULT_INTERVAL, "--timeout": DEFAULT_TIMEOUT}
    args = argv[1:]
    while args:
        if args[0] in opts and len(args) > 1:
            opts[args[0]] = type(opts[args[0]])(args[1])
            args = args[2:]
        else:
            print(f"bench_guard: unknown argument {args[0]}", file=sys.stderr)
            return 2
    if wait_quiet(opts["--threshold"], opts["--samples"], opts["--interval"], opts["--timeout"]):
        print(f"bench_guard: quiet (no process above {opts['--threshold']:.0f}% "
              f"across {opts['--samples']} samples)", flush=True)
        return 0
    print(f"bench_guard: REFUSING — the machine did not go quiet within "
          f"{opts['--timeout']}s; no artifact is written (any rounds already "
          "measured are discarded with it)", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
