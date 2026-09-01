"""Render the newest bench artifacts into the marked regions of the docs.

    python3 scripts/render_bench_docs.py            # rewrite regions + spans
    python3 scripts/render_bench_docs.py --check    # exit 1 if any is stale
    python3 scripts/render_bench_docs.py --selftest # prove the checks can fail

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

INLINE SPANS hold the sentences honest the same way the regions hold the
tables. The headline claims live in prose — a reader meets "0.85x Granian
per core" in a paragraph, not a table cell — and prose once carried a
decomposition that did not reconcile with the artifact under it, copied
into three documents before anyone divided it out. The first fix was a
checker holding 24 hand-written regexes against 12 quantities, which meant
every legitimate rewording broke a pattern. This is the second: the number
itself is generated, in place, and the sentence around it stays free.

    ~<!-- num:granian-per-m0@1 -->1.2<!-- /num -->x

The marker names a quantity from ``QUANTITIES`` and the decimals to show;
the renderer writes ``f"{value:.{decimals}f}"`` between the markers, and
``--check`` fails on any span whose text is not what the newest artifact
computes. A span naming an unknown quantity, a quantity whose artifact row
has vanished, or an opener with no closer is an error, not a skip — and
``--selftest`` proves each of those failures fires, because a doc checker
that cannot fail is green having tested nothing.

Two deliberate edges: spans are left untouched when the artifact FAMILY
has never been recorded (a fresh tree without ``bench/results`` mirrors
the regions' leniency), but a missing ROW inside a present artifact is
red — that is a renamed participant, and silently keeping the old number
is how the page starts lying. And the spans carry no tilde, bold or unit;
those belong to the sentence, so the sentence keeps them.
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


SPAN = re.compile(
    r"<!-- num:([a-z0-9-]+)@(\d) -->(.*?)<!-- /num -->", re.S
)
SPAN_OPEN = re.compile(r"<!-- num:")

# Documents whose prose carries spans. BENCHMARKS and WSGI_PERFORMANCE also
# hold generated regions; README.md holds spans only.
SPAN_DOCS = ("README.md", "docs/BENCHMARKS.md", "docs/WSGI_PERFORMANCE.md")


def compute_quantities(layer_medians, asgi_medians):
    """Every quantity the prose may cite, from the two artifact families.

    Pure over its arguments so --selftest can feed doctored medians. Raises
    KeyError naming the missing row when an artifact no longer carries a
    participant the prose quotes — a renamed row must be red, never a
    silently stale number.
    """
    hello = layer_medians["hello(no python,1proc)"]["rps_per_core"]
    m0 = layer_medians["m0serve+bare w1"]["rps_per_core"]
    gran = layer_medians["granian+bare w1"]["rps_per_core"]
    am0 = asgi_medians["m0serve asgi-executor"]
    auv = asgi_medians["uvicorn asyncio"]
    auvl = asgi_medians["uvicorn uvloop"]
    return {
        "hello-rps-k": hello / 1000,
        "m0-wsgi-rps-k": m0 / 1000,
        "granian-rps-k": gran / 1000,
        "m0-per-granian": m0 / gran,
        "granian-per-m0": gran / m0,
        "bridge-tax": hello / m0,
        "granian-w1-cores": layer_medians["granian+bare w1"]["cores"],
        "asgi-vs-uvicorn": am0["rps"] / auv["rps"],
        "asgi-per-core-vs-uvicorn": am0["rps_per_core"] / auv["rps_per_core"],
        "asgi-vs-uvloop": am0["rps"] / auvl["rps"],
        "uvloop-per-core-lead": auvl["rps_per_core"] / am0["rps_per_core"],
    }


def substitute_spans(text, values, where):
    """Every span's body rewritten from `values`. Pure; raises on defects.

    A mangled span cannot be allowed to skip silently: an opener whose
    closer was deleted simply stops matching the pair regex, which without
    the count check would demote "this number is verified" to "this number
    is decoration" with no visible change on the rendered page.
    """
    openers = len(SPAN_OPEN.findall(text))
    spans = list(SPAN.finditer(text))
    if openers != len(spans):
        raise ValueError(
            f"{where}: {openers} span opener(s) but {len(spans)} well-formed"
            " span(s) — a marker is mangled or its closer is gone"
        )

    def sub(m):
        key, decimals, _body = m.group(1), int(m.group(2)), m.group(3)
        if key not in values:
            raise ValueError(
                f"{where}: span names quantity {key!r}, which QUANTITIES"
                " does not define"
            )
        return (
            f"<!-- num:{key}@{decimals} -->"
            f"{values[key]:.{decimals}f}"
            f"<!-- /num -->"
        )

    return SPAN.sub(sub, text)


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


def span_values():
    """The quantity map from the newest artifacts, or None while either
    family has never been recorded (mirrors the regions' leniency for a
    tree without bench/results)."""
    layer, asgi = newest("layer-split"), newest("asgi-wrk-hello")
    if layer is None or asgi is None:
        return None
    try:
        return compute_quantities(
            json.loads(layer.read_text())["medians"],
            json.loads(asgi.read_text())["medians"],
        )
    except KeyError as missing:
        sys.exit(
            f"the newest artifact no longer has the row {missing} that the"
            " prose spans quote — a renamed participant must be re-pointed,"
            " not silently kept at its old number"
        )


def selftest():
    """The span checks must be able to fail, one doctored input per rule."""
    medians = {
        "hello(no python,1proc)": {"rps_per_core": 115_900, "cores": 1.0},
        "m0serve+bare w1": {"rps_per_core": 85_200, "cores": 1.0},
        "granian+bare w1": {"rps_per_core": 100_000, "cores": 1.75},
    }
    asgi = {
        "m0serve asgi-executor": {"rps": 60_000, "rps_per_core": 60_000},
        "uvicorn asyncio": {"rps": 56_600, "rps_per_core": 56_600},
        "uvicorn uvloop": {"rps": 81_000, "rps_per_core": 81_000},
    }
    values = compute_quantities(medians, asgi)

    def expect(label, fn, needle):
        try:
            fn()
        except (ValueError, KeyError) as e:
            if needle in str(e):
                print(f"  caught          {label}")
                return True
            print(f"  MISATTRIBUTED   {label}\n     got: {e}")
            return False
        print(f"  MISSED          {label} — no error was raised")
        return False

    good = "net ~<!-- num:granian-per-m0@2 -->1.17<!-- /num -->x per core"
    ok = True

    rendered = substitute_spans(good, values, "selftest")
    if rendered != good:
        print(f"  MISSED          a current span was rewritten: {rendered!r}")
        ok = False
    else:
        print("  caught          (control: a current span is left byte-identical)")

    stale = good.replace("1.17", "1.35")
    if substitute_spans(stale, values, "selftest") == stale:
        print("  MISSED          a stale span survived substitution")
        ok = False
    else:
        print("  caught          a stale span is rewritten (--check goes red)")

    ok &= expect(
        "a span naming an unknown quantity",
        lambda: substitute_spans(
            good.replace("granian-per-m0", "no-such-quantity"), values,
            "selftest"),
        "QUANTITIES does not define",
    )
    ok &= expect(
        "a span whose closer is deleted",
        lambda: substitute_spans(
            good.replace("<!-- /num -->", ""), values, "selftest"),
        "closer is gone",
    )
    ok &= expect(
        "an artifact that loses a row the prose quotes",
        lambda: compute_quantities(
            {k: v for k, v in medians.items() if k != "granian+bare w1"},
            asgi),
        "granian+bare w1",
    )

    shown = f"{values['granian-per-m0']:.1f}"
    if shown != "1.2":
        print(f"  MISSED          decimals formatting drifted: {shown!r}")
        ok = False
    else:
        print("  caught          (control: @1 renders one decimal, rounded)")

    print("render_bench_docs selftest: " + ("PASS" if ok else "FAIL"))
    return ok


def main():
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    check = "--check" in sys.argv
    values = span_values()
    stale, written = [], []
    span_only = [
        REPO / rel for rel in SPAN_DOCS if (REPO / rel) not in TARGETS
    ]
    for doc in list(TARGETS) + span_only:
        kinds = TARGETS.get(doc, [])
        if not doc.exists():
            sys.exit(f"{doc.relative_to(REPO)} does not exist")
        current = doc.read_text()
        new = rewrite(doc, kinds)
        if values is not None and str(doc.relative_to(REPO)) in SPAN_DOCS:
            try:
                new = substitute_spans(
                    new, values, str(doc.relative_to(REPO)))
            except ValueError as e:
                sys.exit(str(e))
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
                "generated bench table(s) or prose span(s) are stale for the"
                f" newest artifacts in {', '.join(stale)} - run:"
                " uv run poe render-bench-docs"
            )
        print("generated bench tables and prose spans: current")
    elif written:
        print("rendered the newest artifacts into " + ", ".join(written))
    else:
        print("generated bench tables and prose spans: already current")


if __name__ == "__main__":
    main()
