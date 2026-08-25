"""Render the newest bench artifact into WSGI_PERFORMANCE.md's marked region.

    python3 scripts/render_bench_docs.py            # rewrite the region
    python3 scripts/render_bench_docs.py --check    # exit 1 if it is stale

The region sits between these markers, which must both exist exactly once:

    <!-- generated: layer-split -- edit bench/results, not this table -->
    <!-- /generated: layer-split -->

Everything OUTSIDE the markers is hand-written narrative and is never
touched — the same generated-tables-inside-curated-prose split
project-index's refresh-index.ts uses. Everything INSIDE is replaced
wholesale from the newest ``bench/results/layer-split-*.json``, so the
table cannot drift from the artifact it cites: ``--check`` runs in CI
(via ``poe check-docs``) and fails the build when someone commits a new
artifact without re-rendering, or edits the table by hand.
"""

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOC = REPO / "docs" / "WSGI_PERFORMANCE.md"
BEGIN = "<!-- generated: layer-split -- edit bench/results, not this table -->"
END = "<!-- /generated: layer-split -->"

# Presentation order and labels for the rows the bench produces.
ROW_ORDER = [
    ("hello(no python,1proc)", "`apps/hello` — mojo-http HTTP layer, zero Python"),
    ("m0serve+bare w1", "`m0serve` + bare WSGI, 1 worker"),
    ("granian+bare w1", "`granian` + bare WSGI, 1 worker"),
    ("m0serve+bare w4", "`m0serve` + bare WSGI, 4 workers"),
    ("granian+bare w4", "`granian` + bare WSGI, 4 workers"),
]


def newest_artifact():
    files = sorted((REPO / "bench" / "results").glob("layer-split-*.json"))
    if not files:
        sys.exit("no bench/results/layer-split-*.json artifacts exist yet")
    return files[-1]


def render(path):
    d = json.loads(path.read_text())
    env = d["environment"]
    p = d["parameters"]
    lines = [
        BEGIN,
        f"Source: [`{path.name}`](../bench/results/{path.name}) — "
        f"{d['recorded_utc']}, commit `{env.get('git_sha', '?')}`"
        f"{' (dirty tree)' if env.get('git_dirty') else ''}.",
        f"Environment: {env.get('python', '?').split(' (')[0]}; "
        f"{env.get('granian') or 'granian absent'}; {env.get('cpu', '?')}; "
        f"wrk -c{p.get('connections', '?')} -d{p.get('duration', '?')}, "
        f"{p.get('rounds', '?')} rounds, medians.",
        "",
        "| row | rps | cores | rps/core |",
        "|-----|----:|------:|---------:|",
    ]
    med = d["medians"]
    for key, label in ROW_ORDER:
        if key not in med:
            continue
        m = med[key]
        cores = f"{m['cores']:.2f}" if "cores" in m else "—"
        per = f"{m['rps_per_core']:,}" if "rps_per_core" in m else "—"
        lines.append(f"| {label} | {m['rps']:,.0f} | {cores} | {per} |")
    for key in med:
        if key not in dict(ROW_ORDER):
            m = med[key]
            lines.append(f"| {key} | {m['rps']:,.0f} | — | — |")
    lines.append("")
    lines.append(
        "Cores are measured (sampled `%cpu` of the pids on the listen"
        " socket), not configured — the column exists because a \"1 worker\""
        " comparator was found running 1.6 cores. Cross-session absolute"
        " rps on this hardware varies ~1.5x; within-run ratios are the"
        " signal."
    )
    lines.append(END)
    return "\n".join(lines)


def main():
    check = "--check" in sys.argv
    text = DOC.read_text()
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        sys.exit(
            f"{DOC.name} must contain exactly one layer-split generated"
            " region (see render_bench_docs.py's docstring)"
        )
    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    new = head + render(newest_artifact()) + tail
    if check:
        if new != text:
            sys.exit(
                "docs/WSGI_PERFORMANCE.md's generated table is stale for the"
                " newest bench artifact - run: uv run poe render-bench-docs"
            )
        print("generated bench table: current")
        return
    if new == text:
        print("generated bench table: already current")
        return
    DOC.write_text(new)
    print("rendered the newest artifact into docs/WSGI_PERFORMANCE.md")


if __name__ == "__main__":
    main()
