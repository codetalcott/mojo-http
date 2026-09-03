"""Record one CI measurement as a line of JSON, and never fail doing it.

    python3 scripts/emit.py METRIC VALUE [--unit KB] [--limit 12288] [--task smoke-django]

The smoke tasks already measure real quantities and print them:

    rss growth over 10k requests: 4096KB (limit 12288KB)
    fast request served in 41ms with two 1.5s views in flight
    sendfile: RSS 12480KB -> 15120KB (grew 2640KB) after 3x64MB

Every one of those is thrown away. They go to a job log that expires, so the
only question anyone can answer is "did it pass", never "is it drifting toward
the limit". A guard at 12288KB that has quietly moved from 300KB to 11000KB is
one commit from red and nothing says so.

This appends them to `$M0_RESULTS` instead, one JSON object per line. CI
uploads the file and renders it into the job summary.

Two rules, both absolute:

- **It never fails.** Exit status is 0 whatever happens -- a bad argument, an
  unwritable path, a full disk. A recording failure must never turn a passing
  gate red, and must never be mistaken for the thing being measured. This is
  the same discipline `scripts/bench_asgi.py` already applies by wrapping its
  `write_artifact` call in try/except so a recording failure cannot mask the
  gate.
- **It is a no-op when `M0_RESULTS` is unset.** Running a smoke locally writes
  nothing anywhere, which is what makes it safe to call from inside a task
  body without conditioning every call site on being in CI.

`--selftest` proves both, plus the append and the schema.
"""

import json
import os
import sys
from datetime import datetime, timezone


def emit_covers(rid, task=None, path=None, tag=None):
    """Append one coverage record: this run exercised SPEC row `rid`.

    The F12 half of the recorder (docs/notes/traceability.md): a smoke
    declares the capability it covers IN its own body, so coverage is
    recorded by a real run rather than asserted by the sheet. The static
    checker (`scripts/spec_sheet.py`) reads the same `--covers` call sites
    out of the task bodies; this records that the declaring line actually
    ran. Same two absolutes as `emit`: never fails, and a no-op without
    `$M0_RESULTS`.
    """
    try:
        path = path if path is not None else os.environ.get("M0_RESULTS")
        if not path:
            return False
        rec = {
            "covers": str(rid),
            "recorded_utc": datetime.now(timezone.utc).isoformat(),
        }
        if task:
            rec["task"] = task
        tag = tag if tag is not None else os.environ.get("M0_RESULTS_TAG")
        if tag:
            rec["tag"] = tag
        with open(path, "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        return True
    except Exception:
        return False


def emit(metric, value, unit=None, limit=None, task=None, path=None, tag=None):
    """Append one record. Returns True if written, False if not; never raises."""
    try:
        path = path if path is not None else os.environ.get("M0_RESULTS")
        if not path:
            return False
        try:
            number = float(value)
            number = int(number) if number.is_integer() else number
        except (TypeError, ValueError):
            # Keep it rather than dropping the measurement, but as `str` --
            # an unserialisable value would otherwise fail json.dumps below
            # and lose the record entirely, which the selftest caught.
            number = str(value)
        rec = {
            "metric": metric,
            "value": number,
            "recorded_utc": datetime.now(timezone.utc).isoformat(),
        }
        if unit:
            rec["unit"] = unit
        if limit is not None:
            try:
                lim = float(limit)
                # int() only when it is exactly integral: `--limit 0.25` used
                # to store 0, which made every headroom percentage infinite
                # and the guard look breached. Found the moment a metric was
                # recorded in seconds instead of milliseconds.
                rec["limit"] = int(lim) if lim.is_integer() else lim
            except (TypeError, ValueError):
                pass
        if task:
            rec["task"] = task
        tag = tag if tag is not None else os.environ.get("M0_RESULTS_TAG")
        if tag:
            rec["tag"] = tag
        with open(path, "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        return True
    except Exception:
        # Deliberately bare. Nothing this file can hit is worth failing a smoke
        # over, and a traceback on stderr inside a task body reads as the task
        # misbehaving.
        return False


def _selftest():
    import tempfile

    ok = True

    def check(label, cond):
        nonlocal ok
        print(("  ok   " if cond else "  FAIL ") + label)
        ok = ok and cond

    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "results.jsonl")

        check("no path and no M0_RESULTS writes nothing",
              emit("m", 1, path=None) is False or not os.environ.get("M0_RESULTS"))

        check("writes a record when given a path", emit("rss", 4096, unit="KB",
              limit=12288, task="smoke-x", path=p, tag="ubuntu") is True)
        rec = json.loads(open(p).read().strip())
        check("metric round-trips", rec["metric"] == "rss")
        check("value is numeric, not a string", rec["value"] == 4096)
        check("unit, limit, task, tag recorded",
              (rec["unit"], rec["limit"], rec["task"], rec["tag"])
              == ("KB", 12288, "smoke-x", "ubuntu"))
        check("timestamp present", "recorded_utc" in rec)

        emit("rss", 5120, path=p)
        check("appends rather than truncating",
              len(open(p).read().strip().splitlines()) == 2)

        check("a float value survives", emit("t", 1.5, path=p) is True)
        check("a non-numeric value is kept, not dropped",
              emit("v", "n/a", path=p) is True
              and json.loads(open(p).read().strip().splitlines()[-1])["value"] == "n/a")
        check("every line is valid json",
              all(json.loads(l) for l in open(p).read().strip().splitlines()))

        check("an unwritable path is survived, not raised",
              emit("m", 1, path=os.path.join(d, "no", "such", "dir", "f")) is False)
        check("a value that cannot be floated is survived",
              emit("m", object(), path=p) is True)

        table = summarise(p)
        check("summary renders a markdown table", table.startswith("### Measurements"))
        check("summary shows headroom against the limit", "% of limit" in table)
        # Rows are keyed by (metric, tag): the same metric measured on macOS
        # and on Linux are two rows, not a race between them.
        check("summary keeps a row per tag", "4096" in table and "5120" in table)
        p2 = os.path.join(d, "same-tag.jsonl")
        emit("rss", 111, path=p2, tag="ubuntu")
        emit("rss", 222, path=p2, tag="ubuntu")
        t2 = summarise(p2)
        check("within one tag the NEWEST value wins",
              "222" in t2 and "111" not in t2)
        check("summary of a missing file is empty, not an error",
              summarise(os.path.join(d, "nope.jsonl")) == "")

        p3 = os.path.join(d, "fractional.jsonl")
        emit("t", 0.0004, unit="s", limit=0.25, path=p3)
        r3 = json.loads(open(p3).read().strip())
        check("a fractional limit is not truncated to zero", r3["limit"] == 0.25)
        check("headroom against a fractional limit is finite",
              "0% of limit" in summarise(p3))

        # --covers (SPEC F12): same absolutes, and the summary must not
        # bury the measurements under a hundred declaration rows.
        p4 = os.path.join(d, "covers.jsonl")
        check("a coverage record is written",
              emit_covers("A7", task="smoke-pipelining", path=p4) is True)
        r4 = json.loads(open(p4).read().strip())
        check("the coverage record carries the id and task",
              (r4["covers"], r4["task"]) == ("A7", "smoke-pipelining"))
        check("no path and no M0_RESULTS writes no coverage",
              emit_covers("A7", path=None) is False
              or bool(os.environ.get("M0_RESULTS")))
        check("an unwritable path is survived by --covers too",
              emit_covers("A7", path=os.path.join(d, "no", "dir", "f")) is False)
        emit("rss", 64, unit="KB", limit=128, path=p4)
        emit_covers("A8", path=p4)
        t4 = summarise(p4)
        check("coverage renders as a tally, not table rows",
              "2 SPEC row(s) declared covered" in t4 and "A7" not in t4)
        check("measurements still render beside coverage", "rss" in t4)
        check("a coverage-only file summarises to its tally",
              "1 SPEC row(s) declared covered" in summarise(
                  (emit_covers("B1", path=os.path.join(d, "only.jsonl")),
                   os.path.join(d, "only.jsonl"))[1]))

    print("emit selftest: " + ("PASS" if ok else "FAIL"))
    return ok


def summarise(path):
    """Render the recorded lines as a markdown table, newest value per metric.

    The `headroom` column is the point of the whole exercise. A guard at
    12288KB tells you pass or fail; it does not tell you the measurement has
    moved from 300KB to 11000KB and is one commit from red. Percent of limit
    does.
    """
    try:
        lines = [json.loads(l) for l in open(path) if l.strip()]
    except Exception:
        return ""
    if not lines:
        return ""
    # Coverage records (`--covers`, SPEC F12) are declarations, not
    # measurements: 100+ of them as table rows would bury the headroom
    # column the table exists for, so they render as one tally line.
    covered = sorted({rec["covers"] for rec in lines if "covers" in rec})
    lines = [rec for rec in lines if "covers" not in rec]
    if not lines:
        return (f"{len(covered)} SPEC row(s) declared covered by this run\n"
                if covered else "")
    rows = {}
    for rec in lines:
        rows[(rec.get("metric"), rec.get("tag"))] = rec
    out = ["### Measurements", "",
           "| metric | value | limit | headroom | task | run on |",
           "|---|---:|---:|---:|---|---|"]
    for (metric, tag), r in sorted(rows.items(), key=lambda kv: (kv[0][0] or "", kv[0][1] or "")):
        unit = r.get("unit", "")
        value, limit = r.get("value"), r.get("limit")
        head = ""
        try:
            if limit:
                head = f"{100.0 * float(value) / float(limit):.0f}% of limit"
        except (TypeError, ValueError):
            head = ""
        out.append(
            f"| `{metric}` | {value}{unit} | {str(limit) + unit if limit else ''} "
            f"| {head} | {r.get('task', '')} | {tag or ''} |"
        )
    if covered:
        out += ["", f"{len(covered)} SPEC row(s) declared covered by this run"]
    return "\n".join(out) + "\n"


def main():
    argv = sys.argv[1:]
    if "--selftest" in argv:
        sys.exit(0 if _selftest() else 1)
    if "--summary" in argv:
        i = argv.index("--summary")
        src = argv[i + 1] if i + 1 < len(argv) else os.environ.get("M0_RESULTS", "")
        sys.stdout.write(summarise(src) if src else "")
        sys.exit(0)
    opts, pos = {}, []
    i = 0
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opts[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            pos.append(argv[i])
            i += 1
    if "covers" in opts:
        emit_covers(opts["covers"], task=opts.get("task"))
    elif len(pos) >= 2:
        emit(pos[0], pos[1], unit=opts.get("unit"), limit=opts.get("limit"),
             task=opts.get("task"))
    # Always 0. See the module docstring.
    sys.exit(0)


if __name__ == "__main__":
    main()
