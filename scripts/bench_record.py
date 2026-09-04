"""Turn a benchmark's text output into a dated, environment-stamped artifact.

    python3 scripts/bench_record.py layer_split /tmp/bench_layer_split.txt
    python3 scripts/bench_record.py wsgi_modes /tmp/bench_wsgi_modes.txt
    python3 scripts/bench_record.py mixed_workload /tmp/bench_mixed_workload.txt

Each bench's text rows have their own parser in PARSERS below;
``bench_asgi.py`` skips the text round-trip and calls ``write_artifact``
directly. A bench name not in the registry is an error, not a guess.

Writes ``bench/results/<bench>-<UTC timestamp>.json`` and prints the path.

Why this exists: the numbers in docs/WSGI_PERFORMANCE.md used to be
transcribed from terminal scrollback, and every transcription lost the
metadata that later decided whether the numbers were comparable at all —
which interpreter build (3.14.7t and 3.14.0rc2 measured within 5%, but the
docs could not have said so), which comparator version (2.8.1 vs 2.8.2),
and how many cores each server actually consumed (Granian's "1 worker" ran
at ~1.6 cores, which silently skewed every per-server ratio for weeks).
The artifact captures all of it at the moment of measurement, so a doc can
cite a file instead of asserting a number.

Absolute rps on a laptop is NOT comparable across sessions — the recorded
history shows identical binaries moving ~1.5x between days. Within-run
ratios are the stable signal, which is why every artifact holds a complete
run rather than one row.
"""

import json
import platform
import re
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "bench" / "results"

_US = {"us": 1.0, "ms": 1000.0, "s": 1_000_000.0}

# One measured row of bench_layer_split.sh's output, e.g.:
#   r1 hello(no python,1proc)  rps  94072.83 p50 153.00us ... cores  1.01
_LAYER_ROW = re.compile(
    r"^r(?P<round>\d+)\s+(?P<name>\S.*?)\s+rps\s+(?P<rps>[\d.]+)"
    r"\s+p50\s+(?P<p50>[\d.]+)(?P<p50u>us|ms|s)"
    r"\s+p90\s+(?P<p90>[\d.]+)(?P<p90u>us|ms|s)"
    r"\s+p99\s+(?P<p99>[\d.]+)(?P<p99u>us|ms|s)"
    r"\s+max\s+(?P<max>[\d.]+)(?P<maxu>us|ms|s)"
    r"(?:\s+cores\s+(?P<cores>[\d.]+|\?))?"
)

# bench_wsgi_modes.sh (ab, two sub-measurements per row):
#   r1 m0serve --workers 2  keepalive 12345.67 rps p50 1 p99 3 ms | close ...
_MODES_ROW = re.compile(
    r"^r(?P<round>\d+)\s+(?P<name>\S.*?)\s+keepalive\s+(?P<rps>[\d.]+)\s+rps"
    r"\s+p50\s+(?P<p50_ms>[\d.]+)\s+p99\s+(?P<p99_ms>[\d.]+)\s+ms"
    r"\s+\|\s+close\s+(?P<close_rps>[\d.]+)\s+rps"
    r"\s+p50\s+(?P<close_p50_ms>[\d.]+)\s+p99\s+(?P<close_p99_ms>[\d.]+)\s+ms"
    r"\s+\|\s+failed\s+(?P<failed_ka>\d+)/(?P<failed_close>\d+)"
    r"\s+\|\s+rss\s+(?P<rss_kb>\d+)\s+KB"
)

# bench_mixed_workload.sh (no rounds; the config IS the row identity):
#   m0serve --workers 4 +bt=4        slow=4  fast rps  12345.67 p50 ...
_MIXED_ROW = re.compile(
    r"^(?P<name>\S.*?)\s+slow=(?P<slow>\d+)\s+fast rps\s+(?P<rps>[\d.]+)"
    r"\s+p50\s+(?P<p50>[\d.]+)(?P<p50u>us|ms|s)"
    r"\s+p90\s+(?P<p90>[\d.]+)(?P<p90u>us|ms|s)"
    r"\s+p99\s+(?P<p99>[\d.]+)(?P<p99u>us|ms|s)"
    r"\s+max\s+(?P<max>[\d.]+)(?P<maxu>us|ms|s)"
)


def _parse_layer_split(text):
    rows = []
    for line in text.splitlines():
        m = _LAYER_ROW.match(line.strip())
        if not m:
            continue
        d = m.groupdict()
        row = {
            "round": int(d["round"]),
            "name": d["name"].strip(),
            "rps": float(d["rps"]),
            "p50_us": float(d["p50"]) * _US[d["p50u"]],
            "p90_us": float(d["p90"]) * _US[d["p90u"]],
            "p99_us": float(d["p99"]) * _US[d["p99u"]],
            "max_us": float(d["max"]) * _US[d["maxu"]],
        }
        if d["cores"] and d["cores"] != "?":
            row["cores"] = float(d["cores"])
        rows.append(row)
    return rows


def _parse_wsgi_modes(text):
    rows = []
    for line in text.splitlines():
        m = _MODES_ROW.match(line.strip())
        if not m:
            continue
        d = m.groupdict()
        rows.append({
            "round": int(d["round"]),
            "name": d["name"].strip(),
            "rps": float(d["rps"]),  # the keep-alive run is the headline
            "p50_us": float(d["p50_ms"]) * 1000.0,
            "p99_us": float(d["p99_ms"]) * 1000.0,
            "close_rps": float(d["close_rps"]),
            "close_p50_us": float(d["close_p50_ms"]) * 1000.0,
            "close_p99_us": float(d["close_p99_ms"]) * 1000.0,
            "failed_keepalive": int(d["failed_ka"]),
            "failed_close": int(d["failed_close"]),
            "rss_kb": int(d["rss_kb"]),
        })
    return rows


def _parse_mixed_workload(text):
    rows = []
    for line in text.splitlines():
        m = _MIXED_ROW.match(line.strip())
        if not m:
            continue
        d = m.groupdict()
        rows.append({
            # slow-load level folded into the identity: the same server
            # config under slow=0 and slow=4 are different measurements.
            "name": f"{d['name'].strip()} slow={d['slow']}",
            "rps": float(d["rps"]),
            "p50_us": float(d["p50"]) * _US[d["p50u"]],
            "p90_us": float(d["p90"]) * _US[d["p90u"]],
            "p99_us": float(d["p99"]) * _US[d["p99u"]],
            "max_us": float(d["max"]) * _US[d["maxu"]],
        })
    return rows


PARSERS = {
    "layer_split": _parse_layer_split,
    # Same row shape as the layer split (bench_asgi_wrk.sh prints it);
    # the artifact name is what docs/BENCHMARKS.md's generated region keys on.
    "asgi_wrk_hello": _parse_layer_split,
    # The same script at 256 connections (BENCH_CONNS=256 BENCH_NAME=asgi_wrk_conns):
    # the saturation row, where per-core and per-process rankings differ.
    "asgi_wrk_conns": _parse_layer_split,
    # Framework apps through the same script (BENCH_NAME=...): the rows the
    # WSGI_PERFORMANCE.md framework table quotes; not on the benchmark page,
    # whose rows are bare handlers on purpose.
    "asgi_wrk_fasthtml": _parse_layer_split,
    "asgi_wrk_django": _parse_layer_split,
    # apps/hello under wrk, two builds side by side (an A/B of the Mojo HTTP
    # layer alone, no Python): the rows SERVER_PERFORMANCE.md's parse-lever
    # table quotes. Not on the benchmark page.
    "hello_wrk": _parse_layer_split,
    "wsgi_modes": _parse_wsgi_modes,
    "mixed_workload": _parse_mixed_workload,
}


def _cmd(*argv):
    try:
        return subprocess.run(
            argv, capture_output=True, text=True, timeout=30
        ).stdout.strip()
    except Exception:
        return ""


def _tree_is_dirty():
    """Is the WORKING TREE dirty, ignoring bench artifacts?

    `git status --porcelain` counts untracked files, and a benchmark run
    writes its artifact into bench/results/ -- so running two benches back
    to back stamped the second one `git_dirty: true` because the FIRST
    one's artifact was sitting there untracked. That is a false provenance
    warning on the worst possible field: the flag exists to tell a reader
    the measured code may not match the recorded commit, and a sibling
    result file says nothing about the code.

    Artifacts under bench/results/ are therefore excluded. Anything else --
    including an uncommitted change to a bench script -- still counts.
    """
    status = _cmd("git", "-C", str(REPO), "status", "--porcelain") or ""
    for line in status.splitlines():
        path = line[3:].strip().strip('"')
        if path.startswith("bench/results/"):
            continue
        return True
    return False


def environment():
    venv = REPO / ".venv" / "bin"
    env = {
        "git_sha": _cmd("git", "-C", str(REPO), "rev-parse", "--short", "HEAD"),
        "git_dirty": _tree_is_dirty(),
        "os": f"{platform.system()} {platform.release()}",
        "machine": platform.machine(),
        "python": _cmd(str(venv / "python3"), "-VV"),
        "mojo": _cmd(str(venv / "mojo"), "--version").splitlines()[0]
        if (venv / "mojo").exists()
        else "",
        "granian": _cmd(str(venv / "granian"), "--version"),
        "wrk": (_cmd("wrk", "--version") or _cmd("wrk", "-v")).splitlines()[0]
        if _cmd("wrk", "--version") or _cmd("wrk", "-v")
        else "",
    }
    if platform.system() == "Darwin":
        env["cpu"] = _cmd("sysctl", "-n", "machdep.cpu.brand_string")
        env["cores_physical"] = _cmd("sysctl", "-n", "hw.physicalcpu")
    else:
        model = ""
        try:
            for line in open("/proc/cpuinfo"):
                if line.startswith("model name"):
                    model = line.split(":", 1)[1].strip()
                    break
        except OSError:
            pass
        env["cpu"] = model
    return env


def medians(rows):
    by_name = {}
    for r in rows:
        by_name.setdefault(r["name"], []).append(r)
    out = {}
    for name, rs in by_name.items():
        med = {"rps": statistics.median(r["rps"] for r in rs)}
        cores = [r["cores"] for r in rs if "cores" in r]
        if cores:
            med["cores"] = statistics.median(cores)
            med["rps_per_core"] = round(med["rps"] / max(med["cores"], 0.01))
        out[name] = med
    return out


def write_artifact(bench, rows, meta):
    """Write one artifact and print its path. Importable for Python benches
    (bench_asgi.py builds its rows in memory and skips the text round trip).
    """
    RESULTS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = RESULTS / f"{bench.replace('_', '-')}-{stamp}.json"
    artifact = {
        "bench": bench,
        "recorded_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "environment": environment(),
        "parameters": meta,
        "rows": rows,
        "medians": medians(rows),
    }
    path.write_text(json.dumps(artifact, indent=2) + "\n")
    print(f"bench artifact: {path.relative_to(REPO)}")
    return path


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: bench_record.py <bench-name> <text-output> [--meta k=v ...]")
    bench, source = sys.argv[1], Path(sys.argv[2])
    meta = {}
    args = sys.argv[3:]
    while args:
        if args[0] == "--meta" and len(args) > 1:
            k, _, v = args[1].partition("=")
            meta[k] = v
            args = args[2:]
        else:
            sys.exit(f"unknown argument: {args[0]}")

    if bench not in PARSERS:
        sys.exit(f"unknown bench '{bench}'; known: {', '.join(sorted(PARSERS))}")
    rows = PARSERS[bench](source.read_text())
    if not rows:
        sys.exit(f"no measured rows found in {source} - nothing recorded")
    write_artifact(bench, rows, meta)


if __name__ == "__main__":
    main()
