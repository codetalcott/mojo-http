"""Render the newest bench artifacts into the marked regions of the docs.

    python3 scripts/render_bench_docs.py            # rewrite every region
    python3 scripts/render_bench_docs.py --check    # exit 1 if any is stale

A region is a pair of markers naming a bench kind, and it must appear
exactly once in the document that declares it:

    <!-- generated: layer-split -- edit bench/results, not this table -->
    <!-- /generated: layer-split -->

Everything OUTSIDE the markers is hand-written narrative and is never
touched — the same generated-tables-inside-curated-prose split
project-index's refresh-index.ts uses. Everything INSIDE is replaced
wholesale from the newest ``bench/results/<kind>-*.json``, so a table
cannot drift from the artifact it cites: ``--check`` runs in CI (via
``poe check-docs``) and fails the build when someone commits a new
artifact without re-rendering, or edits a table by hand.

Four kinds are rendered, across two documents. docs/WSGI_PERFORMANCE.md is
the working record — narrative, dead ends, the measurements that inverted a
conclusion. docs/BENCHMARKS.md is the public page, and the reason it renders
from the same artifacts rather than quoting the working record is the whole
premise of publishing numbers at all: a public claim and a private
measurement that can disagree eventually do.

A kind with no artifact yet renders a stated absence rather than nothing.
That is deliberate — ``mixed-workload`` is the strongest claim this project
makes and the last to get an artifact, and a page that silently omitted it
would read as if the row did not exist.
"""

import json
import re
import statistics
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "bench" / "results"

CORES_NOTE = (
    "Cores are measured (sampled `%cpu` of the pids on the listen socket),"
    " not configured — the column exists because a \"1 worker\" comparator"
    " was found running 1.6 cores. Cross-session absolute rps on this"
    " hardware varies ~1.5x; within-run ratios are the signal."
)

# Presentation order and labels, per kind. A median key the list does not
# name still renders, at the end, without a label -- a new row appears in
# the table rather than vanishing from it.
ROW_ORDER = {
    "layer-split": [
        ("hello(no python,1proc)", "`apps/hello` — mojo-http HTTP layer, zero Python"),
        ("m0serve+bare w1", "`m0serve` + bare WSGI, 1 worker"),
        ("granian+bare w1", "`granian` + bare WSGI, 1 worker"),
        ("m0serve+bare w4", "`m0serve` + bare WSGI, 4 workers"),
        ("granian+bare w4", "`granian` + bare WSGI, 4 workers"),
    ],
    "asgi-wrk-hello": [
        ("m0serve asgi-executor", "`m0serve` — zero-config executor (its loop is stamped above)"),
        ("uvicorn asyncio", "`uvicorn --loop asyncio`"),
        ("uvicorn uvloop", "`uvicorn` with uvloop — what `pip install uvicorn[standard]` runs by default"),
    ],
    "asgi-executor": [
        ("m0serve", "`m0serve` — asyncio executor"),
        ("uvicorn", "`uvicorn`"),
    ],
    "mixed-workload": [],
}


def begin(kind):
    return f"<!-- generated: {kind} -- edit bench/results, not this table -->"


def end(kind):
    return f"<!-- /generated: {kind} -->"


def newest(kind):
    files = sorted(RESULTS.glob(f"{kind}-*.json"))
    return files[-1] if files else None


def participants(d):
    """The row and median names, lowercased -- who is actually in the run."""
    names = set(d.get("medians", {}))
    names.update(r.get("name", "") for r in d.get("rows", []))
    return " ".join(names).lower()


def provenance(path, d):
    env = d["environment"]
    p = d.get("parameters", {})
    bits = [
        f"Source: [`{path.name}`](../bench/results/{path.name}) — "
        f"{d['recorded_utc']}, commit `{env.get('git_sha', '?')}`"
        f"{' (dirty tree)' if env.get('git_dirty') else ''}."
    ]
    envline = f"Environment: {env.get('python', '?').split(' (')[0]}"
    # The recorder stamps every tool it can see, including ones this bench
    # does not run. Naming a comparator with no row in the table reads, on a
    # public page, as if it had been measured and lost.
    if env.get("granian") and "granian" in participants(d):
        envline += f"; {env['granian']}"
    envline += f"; {env.get('cpu', '?')}"
    if env.get("cores_physical"):
        envline += f" ({env['cores_physical']} cores)"
    # `client` is the bench's own description of how it drove the server;
    # the wrk-shaped params are spelled as the command they came from,
    # because "wrk -c16 -d10s, 3 rounds, medians" is what a reader can
    # actually re-run. Anything else falls back to the raw parameters.
    if p.get("client"):
        detail = p["client"]
    elif "connections" in p and "duration" in p:
        detail = f"wrk -c{p['connections']} -d{p['duration']}"
        if p.get("rounds"):
            detail += f", {p['rounds']} rounds"
        detail += ", medians"
    else:
        detail = ", ".join(
            f"{k}={v}" for k, v in p.items() if k not in ("app", "note")
        )
    if detail:
        envline += f"; {detail}"
    # Which loop the executor ran on is a property of the interpreter
    # m0serve resolved from PATH, not of the code -- the shim adopts uvloop
    # only where it can import it -- so an artifact that stamped it says so.
    if p.get("executor_loop"):
        envline += f"; executor loop: {p['executor_loop']}"
    bits.append(envline + ".")
    return bits


def ordered(kind, med):
    """Median keys in presentation order, then anything unlabelled."""
    labels = dict(ROW_ORDER.get(kind, []))
    seen = []
    for key, label in ROW_ORDER.get(kind, []):
        if key in med:
            seen.append((key, label))
    for key in med:
        if key not in labels:
            seen.append((key, key))
    return seen


def render_rps_table(kind, path, d):
    """rps / cores / rps-per-core — the layer-split and ASGI throughput shape."""
    lines = provenance(path, d) + ["", "| row | rps | cores | rps/core |",
                                   "|-----|----:|------:|---------:|"]
    med = d["medians"]
    for key, label in ordered(kind, med):
        m = med[key]
        cores = f"{m['cores']:.2f}" if "cores" in m else "—"
        per = f"{m['rps_per_core']:,}" if "rps_per_core" in m else "—"
        lines.append(f"| {label} | {m['rps']:,.0f} | {cores} | {per} |")
    lines += ["", CORES_NOTE]
    return lines


def render_tail_table(kind, path, d):
    """rps plus the fast-request latency split, from the rows rather than
    the medians: p50/p99 live per row, and this bench records one row per
    server rather than one per round."""
    lines = provenance(path, d) + [
        "", "| server | rps | fast p50 | fast p99 | errors |",
        "|--------|----:|---------:|---------:|-------:|",
    ]
    labels = dict(ROW_ORDER.get(kind, []))
    for row in d.get("rows", []):
        name = labels.get(row["name"], row["name"])
        p50 = f"{row['mixed_fast_p50_us']:,.0f} µs" if "mixed_fast_p50_us" in row else "—"
        p99 = f"{row['mixed_fast_p99_us']:,.0f} µs" if "mixed_fast_p99_us" in row else "—"
        lines.append(
            f"| {name} | {row['rps']:,.0f} | {p50} | {p99} |"
            f" {row.get('errors', '—')} |"
        )
    lines += [
        "",
        "Fast-request latency is measured while slow requests are in flight;"
        " rps and the two percentiles come from the same run, so they trade"
        " against each other rather than being separately optimised rows.",
    ]
    return lines


def render_isolation_table(kind, path, d):
    """The pool's whole claim: fast-route p99 as slow load is added.

    Pivoted rather than listed, because the finding is a comparison ACROSS
    the slow levels within one configuration -- a flat row means the pool
    isolated the slow work, a climbing one means connections were stranded
    behind it. A flat list of rows would carry the same numbers and none of
    the shape.

    Percentiles live on the rows rather than in `medians` (bench_record's
    `medians()` folds rps and cores only), so they are re-medianed here
    across rounds. Row names arrive as "r1 --workers 4 slow=0": the round
    prefix is dropped so repeats of one configuration collapse together,
    which is what makes the median meaningful.
    """
    groups, levels = {}, set()
    for row in d.get("rows", []):
        name = row.get("name", "")
        if " slow=" not in name:
            continue
        config, _, slow = name.rpartition(" slow=")
        config = re.sub(r"^r\d+\s+", "", config).strip()
        levels.add(slow)
        groups.setdefault(config, {}).setdefault(slow, []).append(row)

    order = sorted(levels, key=lambda s: int(s))
    lines = provenance(path, d) + [
        "",
        "| configuration | " + " | ".join(f"slow={s}" for s in order) + " |",
        "|---" * (len(order) + 1) + "|",
    ]
    for config in groups:
        cells = []
        for slow in order:
            rs = groups[config].get(slow, [])
            if not rs:
                cells.append("—")
                continue
            p99 = statistics.median(r["p99_us"] for r in rs) / 1000.0
            cells.append(f"{p99:,.1f} ms")
        lines.append(f"| `{config}` | " + " | ".join(cells) + " |")
    lines += [
        "",
        "Fast-route p99, median across rounds, as concurrent slow requests"
        " are added. A row that stays flat isolated the slow work; a row"
        " that climbs toward the slow view's hold time had its connections"
        " stranded behind it. Both halves run in one pass, because a"
        " control that stops failing has stopped measuring anything.",
    ]
    return lines


def render_absent(kind, note):
    return [
        f"_No `{kind}` artifact has been recorded yet._ {note}",
    ]


RENDERERS = {
    "layer-split": render_rps_table,
    "asgi-wrk-hello": render_rps_table,
    "asgi-executor": render_tail_table,
    "mixed-workload": render_isolation_table,
}

ABSENT_NOTE = {
    "mixed-workload": (
        "`scripts/bench_mixed_workload.sh` records one; the numbers quoted"
        " in the prose above predate the artifact system and are therefore"
        " the one claim on this page without a machine-readable source."
        " Reproducing it is documented in"
        " [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md#reproducing)."
    ),
}

# Which document declares which regions. A kind may appear in more than one.
TARGETS = {
    REPO / "docs" / "WSGI_PERFORMANCE.md": ["layer-split"],
    REPO / "docs" / "BENCHMARKS.md": [
        "layer-split", "asgi-wrk-hello", "asgi-executor", "mixed-workload",
    ],
}


def region(kind):
    path = newest(kind)
    if path is None:
        body = render_absent(kind, ABSENT_NOTE.get(kind, ""))
    else:
        d = json.loads(path.read_text())
        body = RENDERERS[kind](kind, path, d)
    return "\n".join([begin(kind)] + body + [end(kind)])


def rewrite(doc, kinds):
    text = doc.read_text()
    for kind in kinds:
        b, e = begin(kind), end(kind)
        if text.count(b) != 1 or text.count(e) != 1:
            sys.exit(
                f"{doc.name} must contain exactly one {kind} generated"
                " region (see render_bench_docs.py's docstring)"
            )
        head, rest = text.split(b, 1)
        _, tail = rest.split(e, 1)
        text = head + region(kind) + tail
    return text


def main():
    check = "--check" in sys.argv
    stale, written = [], []
    for doc, kinds in TARGETS.items():
        if not doc.exists():
            sys.exit(f"{doc.relative_to(REPO)} does not exist")
        current = doc.read_text()
        new = rewrite(doc, kinds)
        if new == current:
            continue
        if check:
            stale.append(str(doc.relative_to(REPO)))
        else:
            doc.write_text(new)
            written.append(str(doc.relative_to(REPO)))
    if check:
        if stale:
            sys.exit(
                "generated bench table(s) are stale for the newest artifacts"
                f" in {', '.join(stale)} - run: uv run poe render-bench-docs"
            )
        print("generated bench tables: current")
    elif written:
        print("rendered the newest artifacts into " + ", ".join(written))
    else:
        print("generated bench tables: already current")


if __name__ == "__main__":
    main()
