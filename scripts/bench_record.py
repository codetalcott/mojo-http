"""Turn a benchmark's text output into a dated, environment-stamped artifact.

    python3 scripts/bench_record.py layer_split /tmp/bench_layer_split.txt

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

# One measured row of bench_layer_split.sh's output, e.g.:
#   r1 hello(no python,1proc)  rps  94072.83 p50 153.00us ... cores  1.01
ROW = re.compile(
    r"^r(?P<round>\d+)\s+(?P<name>\S.*?)\s+rps\s+(?P<rps>[\d.]+)"
    r"\s+p50\s+(?P<p50>[\d.]+)(?P<p50u>us|ms|s)"
    r"\s+p90\s+(?P<p90>[\d.]+)(?P<p90u>us|ms|s)"
    r"\s+p99\s+(?P<p99>[\d.]+)(?P<p99u>us|ms|s)"
    r"\s+max\s+(?P<max>[\d.]+)(?P<maxu>us|ms|s)"
    r"(?:\s+cores\s+(?P<cores>[\d.]+|\?))?"
)

_US = {"us": 1.0, "ms": 1000.0, "s": 1_000_000.0}


def _cmd(*argv):
    try:
        return subprocess.run(
            argv, capture_output=True, text=True, timeout=30
        ).stdout.strip()
    except Exception:
        return ""


def environment():
    venv = REPO / ".venv" / "bin"
    env = {
        "git_sha": _cmd("git", "-C", str(REPO), "rev-parse", "--short", "HEAD"),
        "git_dirty": bool(
            _cmd("git", "-C", str(REPO), "status", "--porcelain")
        ),
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


def parse_rows(text):
    rows = []
    for line in text.splitlines():
        m = ROW.match(line.strip())
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

    rows = parse_rows(source.read_text())
    if not rows:
        sys.exit(f"no measured rows found in {source} - nothing recorded")

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


if __name__ == "__main__":
    main()
