#!/usr/bin/env python3
"""The summaries on the pages read first, held to the rows they restate and
to the code's defaults.

A summary page (llms.txt, the site's home page, the PyPI READMEs, the
skills) restates what a `docs/SPEC.md` row owns, because its reader needs
the fact inline. When the row changes, the summary can go stale with nothing
failing: #661 changed C23, RUNNING.md and MOJO_HOST.md, and llms.txt
contradicted all three for a release.

`docs/copies.json` lists each summary passage: its page, its opening words
(verbatim, unique on the page; whitespace and line breaks are not compared),
the rows it restates with a stamp of each as it stood when the passage was
last read against it, and the code's defaults it states. The passage runs
from its opening words to the end of its paragraph or list item.

- A row whose capability or status no longer matches its stamp fails,
  naming the passage. Re-read the passage against the row, fix it, then
  `uv run poe stamp-copies`, which stamps every stale row and prints what
  it stamped. A row's evidence is not stamped: a renamed gate does not
  change what the summary says.
- A passage whose opening words are gone or appear twice fails.
- A default the passage lists must appear in it as the code states it now
  (FACTS below), so a changed default fails on every page that states it.

What it cannot do: find a summary passage the ledger does not list, or tell
whether a re-stamped passage was read.

    python3 scripts/doc_copies.py            # check
    python3 scripts/doc_copies.py --stamp    # re-stamp stale rows
"""
import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LEDGER = "docs/copies.json"
SPEC = "docs/SPEC.md"

SERVER_CONFIG = "packages/m0-http/lightbug_http/server_config.mojo"
LOOP_STATE = "packages/m0-http/lightbug_http/loop/state.mojo"
CLI = "packages/m0-wsgi/src/cli.mojo"

# name: (source, pattern whose group 1 is the value, how pages write it).
# A default a passage states is named here once; every way a page may spell
# it is listed, and one must appear in the passage.
FACTS = {
    "max_connections": (SERVER_CONFIG, r"self\.max_connections = (\d+)\b",
                        lambda v: [v]),
    "max_connections_cap": (CLI, r"comptime MAX_CONNECTIONS = (\d+)\b",
                            lambda v: [v]),
    "stream_reserve_cap": (SERVER_CONFIG,
                           r"return share if share < (\d+) else \1\b",
                           lambda v: [v]),
    "stream_retry_after_s": (LOOP_STATE,
                             r"comptime STREAM_REFUSED_RETRY_S = (\d+)\b",
                             lambda v: [f"Retry-After: {v}"]),
    "replay_frames": (CLI, r"comptime DEFAULT_REPLAY_FRAMES = (\d+)\b",
                      lambda v: [v]),
    "max_keepalive_requests": (SERVER_CONFIG,
                               r"self\.max_keepalive_requests = (\d+)\b",
                               lambda v: [v]),
    "idle_timeout_s": (SERVER_CONFIG, r"self\.idle_timeout = (\d+)\b",
                       lambda v: [f"{v} s", f"{v}s", f"{v} seconds"]),
    "sse_heartbeat_s": (SERVER_CONFIG, r"self\.sse_heartbeat_ms = (\d+)\b",
                        lambda v: [f"{int(v) // 1000} s", f"{int(v) // 1000}s",
                                   f"{int(v) // 1000} seconds", v]),
    "sse_flush_ms": (LOOP_STATE, r"comptime SSE_FLUSH_MS = (\d+)\b",
                     lambda v: [f"{v} ms", f"{v}ms"]),
    "max_body": (SERVER_CONFIG,
                 r"self\.max_request_body_size = (\d+) \* 1024 \* 1024\b",
                 lambda v: [f"{v}m", f"{v} MB"]),
}

# Where a passage ends: a blank line, or the next list item, heading or
# table row after its first line.
_END = re.compile(r"\n[ \t]*\n|\n[ \t]*(?:[-*+] |\d+\. |#|\|)")


def stamp(row):
    """A row as a summary depends on it: its capability and its status."""
    text = row["capability"] + "\n" + row["status"]
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def _rows(spec_text):
    import spec_sheet
    rows, _ = spec_sheet.parse(spec_text)
    return {r["id"]: r for r in rows}


def _locate(page_text, opens):
    """The passage on the page that opens with `opens`, and how many times
    the opening appears."""
    words = opens.split()
    if not words:
        return None, 0
    found = list(re.finditer(r"\s+".join(map(re.escape, words)), page_text))
    if len(found) != 1:
        return None, len(found)
    m = found[0]
    end = _END.search(page_text, m.end())
    return page_text[m.start():end.start() if end else len(page_text)], 1


def facts(sources):
    """{name: value} for every fact found, and a problem for each missing."""
    values, problems = {}, []
    for name, (path, pattern, _) in FACTS.items():
        m = re.search(pattern, sources.get(path) or "")
        if m:
            values[name] = m.group(1)
        else:
            problems.append(
                f"{LEDGER}: the default `{name}` is no longer where FACTS in "
                f"scripts/doc_copies.py reads it ({path}); point it at the "
                f"line that sets it now")
    return values, problems


def problems(ledger_text, pages, spec_text, sources):
    """Every way the ledger's passages disagree with the rows and defaults
    they state. Pure: `--selftest` hands it doctored copies."""
    try:
        ledger = json.loads(ledger_text)
        passages = ledger["passages"]
    except (TypeError, ValueError, KeyError) as e:
        return [f"{LEDGER} cannot be read: {e}"]
    rows = _rows(spec_text)
    values, out = facts(sources)
    for i, p in enumerate(passages):
        page, opens = p.get("page"), p.get("opens", "")
        where = f"{page}, the passage opening {opens!r}"
        if not p.get("rows") and not p.get("defaults"):
            out.append(f"{LEDGER} #{i}: {where} lists no rows and no defaults")
        text = pages.get(page)
        if text is None:
            out.append(f"{LEDGER} #{i}: {page} does not exist")
            continue
        passage, n = _locate(text, opens)
        if passage is None:
            out.append(
                f"{where}: the opening words appear {n} times on the page, "
                f"and must appear once. Re-point `opens` in {LEDGER} to the "
                f"passage's new opening, after re-reading it against its rows")
            continue
        for rid, stamped in sorted((p.get("rows") or {}).items()):
            row = rows.get(rid)
            if row is None:
                out.append(f"{where}: SPEC has no row {rid}")
            elif stamp(row) != stamped:
                out.append(
                    f"{where}: SPEC {rid} changed since the passage was read "
                    f"against it. Re-read the passage against {rid}, fix it, "
                    f"then `uv run poe stamp-copies`")
        for name in p.get("defaults") or []:
            if name not in FACTS:
                out.append(f"{where}: `{name}` is not a default FACTS knows")
                continue
            if name not in values:
                continue  # reported once, by facts()
            spellings = FACTS[name][2](values[name])
            if not any(re.search(r"(?<![\w.])" + re.escape(s) + r"(?![\w])",
                                 passage) for s in spellings):
                out.append(
                    f"{where}: it states the default `{name}`, which the code "
                    f"sets to {values[name]} ({FACTS[name][0]}), and the "
                    f"passage says none of {spellings}")
    return out


def _inputs(repo):
    ledger_text = (repo / LEDGER).read_text() if (repo / LEDGER).exists() else None
    try:
        names = {p["page"] for p in json.loads(ledger_text)["passages"]}
    except (TypeError, ValueError, KeyError):
        names = set()
    pages = {n: (repo / n).read_text() for n in names if (repo / n).is_file()}
    sources = {path: (repo / path).read_text()
               for path in {f[0] for f in FACTS.values()} if (repo / path).is_file()}
    return ledger_text, pages, (repo / SPEC).read_text(), sources


def check(repo=REPO):
    return problems(*_inputs(repo))


def restamp(repo=REPO):
    """Stamp every stale row in the ledger, printing each passage stamped."""
    ledger = json.loads((repo / LEDGER).read_text())
    rows = _rows((repo / SPEC).read_text())
    changed = 0
    for p in ledger["passages"]:
        for rid in sorted(p.get("rows") or {}):
            if rid in rows and p["rows"][rid] != stamp(rows[rid]):
                p["rows"][rid] = stamp(rows[rid])
                changed += 1
                print(f"stamped {rid} for {p['page']}, the passage opening "
                      f"{p['opens']!r}")
    (repo / LEDGER).write_text(json.dumps(ledger, indent=1, ensure_ascii=False) + "\n")
    print(f"{changed} stamp(s) changed")


def cases(repo=REPO):
    """Each rule reverted against the committed ledger, pages, sheet and
    sources, as (label, ledger, pages, spec, sources, must_fire). A case
    that must fire and changes nothing is NOT APPLICABLE, which the caller
    counts as MISSED."""
    ledger_text, pages, spec, sources = _inputs(repo)
    ledger = json.loads(ledger_text)
    # The cases mutate one passage that states both a row and a default.
    index = next((i for i, p in enumerate(ledger["passages"])
                  if p.get("rows") and p.get("defaults")), None)
    if index is None:
        raise SystemExit(f"{LEDGER}: no passage lists both a row and a "
                         "default, so the selftest has nothing to revert")
    first = ledger["passages"][index]
    page, opens = first["page"], first["opens"]
    rid = sorted(first["rows"])[0]
    default = first["defaults"][0]
    src, pattern, _ = FACTS[default]
    value = re.search(pattern, sources[src]).group(1)
    passage, _ = _locate(pages[page], opens)
    row_line = next(ln for ln in spec.splitlines() if ln.startswith(f"| {rid} |"))

    def with_page(text):
        return {**pages, page: text}

    def with_ledger(edit):
        doc = json.loads(ledger_text)
        edit(doc["passages"][index])
        return json.dumps(doc)

    cap_cell = row_line.split(" | ")[1]
    yield ("a row's capability changes", ledger_text, pages,
           spec.replace(row_line, row_line.replace(cap_cell, cap_cell + " and more", 1)),
           sources, True)
    yield ("a row's status changes", ledger_text, pages,
           spec.replace(row_line, row_line.replace("| verified |", "| implemented |", 1)),
           sources, True)
    yield ("the passage's opening words are rewritten", ledger_text,
           with_page(pages[page].replace(passage, "Reworded. " + passage[len(opens.split()[0]):], 1)),
           spec, sources, True)
    yield ("the passage's opening appears twice", ledger_text,
           with_page(pages[page] + "\n\n" + passage), spec, sources, True)
    yield ("the code's default moves",
           ledger_text, pages, spec,
           {**sources, src: re.sub(pattern, lambda m: m.group(0).replace(value, value + "7", 1),
                                   sources[src], count=1)}, True)
    yield ("the passage drops the default it lists", ledger_text,
           with_page(pages[page].replace(passage, re.sub(
               r"(?<![\w.])" + re.escape(value) + r"(?![\w])", "N", passage), 1)),
           spec, sources, True)
    yield ("the ledger names a row SPEC lacks",
           with_ledger(lambda p: p["rows"].update({"Z999": "0" * 12})),
           pages, spec, sources, True)
    yield ("the ledger names a default FACTS lacks",
           with_ledger(lambda p: p["defaults"].append("no_such_default")),
           pages, spec, sources, True)
    yield ("a default's source line moves away", ledger_text, pages, spec,
           {**sources, src: re.sub(pattern, "moved", sources[src])}, True)
    yield ("(control: the committed ledger)", ledger_text, pages, spec, sources, False)
    evidence = row_line.rstrip(" |").rsplit(" | ", 1)[1]
    yield ("(control: only the row's evidence changes)", ledger_text, pages,
           spec.replace(row_line, row_line.replace(evidence, evidence + " and a gate", 1)),
           sources, False)
    yield ("(control: the passage is re-wrapped)", ledger_text,
           with_page(pages[page].replace(passage, passage.replace(" ", "\n  ", 2), 1)),
           spec, sources, False)


def selftest(repo=REPO):
    ok = True
    real = _inputs(repo)
    for label, ledger_text, pages, spec, sources, must_fire in cases(repo):
        if must_fire and (ledger_text, pages, spec, sources) == real:
            print(f"  MISSED          {label} -- NOT APPLICABLE, the mutation changed nothing")
            ok = False
            continue
        got = problems(ledger_text, pages, spec, sources)
        good = bool(got) == must_fire
        print(f"  {'caught' if good else 'MISSED'}          {label}" + ("" if good else f" -- got {got}"))
        ok &= good
    return ok


def main():
    if "--stamp" in sys.argv:
        restamp()
        return 0
    if "--selftest" in sys.argv:
        return 0 if selftest() else 1
    found = check()
    for msg in found:
        print(f"  - {msg}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
