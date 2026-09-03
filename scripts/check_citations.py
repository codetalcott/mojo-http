"""Citation tracking: every RFC the tree cites must be a current document.

    python3 scripts/check_citations.py             # offline, against the snapshot
    python3 scripts/check_citations.py --update    # refresh scripts/rfc_status.json
    python3 scripts/check_citations.py --live      # monthly: snapshot vs the RFC Editor
    python3 scripts/check_citations.py --selftest  # the rules can fail
    python3 scripts/check_citations.py --sabotage  # each rule, reverted on the real tree

An HTTP server has no HTML spec to keep up with; what it has is a set of
RFCs, and those get obsoleted. RFC 7230 through 7235 were replaced by
9110 to 9112 in June 2022, and when this checker was first run the tree
still cited `RFC 7230 §3.3.3` for message-body length, `RFC 7231
§7.1.1.1` for the date format and `RFC 5987` (obsoleted by 8187) for
encoded header parameters -- in the parser, the chunked decoder, the date
formatter and their tests. Nothing was wrong on the wire; the section
numbers no longer resolved to the documents they named, and nothing could
notice. This is the doc-fact ratchet's philosophy applied to citations:
"is this RFC current?" has a machine source, the RFC Editor's per-document
JSON (`https://www.rfc-editor.org/rfc/rfc9110.json`, with `obsoleted_by`),
so it is never trusted from prose.

Two halves, because the source is on the network and every pull request is
not:

- **Offline, every PR** (`check_docs.py` calls `check()`): every `RFC nnnn`
  in a tracked text file is looked up in `scripts/rfc_status.json`, a
  committed snapshot of the RFC Editor's answers. A citation with no entry
  fails (run `--update`, which fetches it), and a citation of an OBSOLETED
  RFC fails unless the same paragraph names one of its successors -- which
  is how history stays citable: "RFC 2068 §19.7.1 described it; RFC 2616
  dropped it" is fine in a paragraph that also says the header is not in
  RFC 9110. The snapshot is kept honest in both directions: an entry
  nothing cites is stale, and a successor an entry names must itself have
  an entry, so the closure is computable offline.
- **Live, monthly** (`.github/workflows/citations.yml`, `--live`): every
  snapshot entry is re-fetched and compared. An RFC obsoleted since the
  snapshot was taken is the one event the offline half cannot see, and it
  arrives about once a decade per document, so a monthly ask is plenty. The
  workflow is standard library only, like docs.yml, and this file checks
  that the workflow still exists, still has a cron and still passes
  `--live`, for the reason `check_ci_measurements_are_collected` checks
  its `env:` block: a gate that is remembered rather than enforced
  eventually is not.

The rules are pure functions of (citations, snapshot, workflow text), which
is what lets `--sabotage` revert each one in memory against the real tree
and insist the checker catches it, and `--selftest` prove each can fail on
canned input -- including the null case, a paragraph that names the
successor and must PASS. Scanned: every `git ls-files` text file except
lockfiles, benchmark artifacts, generated `docs/spec.json` (its rows are
SPEC.md's, already scanned, and as one line it would be one paragraph),
the snapshot, and this file, whose fixtures cite obsolete RFCs on purpose.

What it cannot do, and does not claim: verify that a SECTION number is
right. `RFC 9112 §6.3` is checked to be a citation of a current document,
not to be the section about message-body length.
"""

import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SNAPSHOT_REL = "scripts/rfc_status.json"
WORKFLOW_REL = ".github/workflows/citations.yml"
SELF_REL = "scripts/check_citations.py"
SNAPSHOT = REPO / SNAPSHOT_REL
WORKFLOW = REPO / WORKFLOW_REL

EXCLUDED_FILES = {SELF_REL, SNAPSHOT_REL, "docs/spec.json"}
EXCLUDED_SUFFIXES = (".lock",)
EXCLUDED_PREFIXES = ("bench/results/",)

# `RFC 9110`, `RFC9110`, `RFC-9110`, `rfc9110` (URLs and JSON ids). Three
# to five digits: RFC 821 is a real document, RFC 100000 is not yet.
CITATION = re.compile(r"\bRFC[ -]?(\d{3,5})\b", re.I)
JSON_URL = "https://www.rfc-editor.org/rfc/rfc{n}.json"
UPDATE_HINT = "run `uv run poe check-citations --update`"


# --- scanning ----------------------------------------------------------------

def tracked_files(repo):
    """Every git-tracked path, relative, as strings."""
    out = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, cwd=repo, check=True
    ).stdout
    return [p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p]


def is_scanned(rel):
    if rel in EXCLUDED_FILES:
        return False
    if rel.endswith(EXCLUDED_SUFFIXES):
        return False
    return not rel.startswith(EXCLUDED_PREFIXES)


def read_text(path):
    """The file's text, or None for a binary (a NUL in its first 8 KB)."""
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\0" in raw[:8192]:
        return None
    return raw.decode("utf-8", "replace")


def find_citations(text):
    """[(line_no, rfc, paragraph_rfcs)] for every RFC citation in `text`.

    A paragraph is a run of non-blank lines; `paragraph_rfcs` is the set of
    RFC numbers cited anywhere in the citation's paragraph, which is what
    the successor rule reads. Numbers are normalised strings ("9110", never
    "09110").
    """
    found = []
    para = []  # (line_no, rfc) of the paragraph being read
    lines = text.split("\n")

    def flush():
        rfcs = {r for _, r in para}
        for line_no, rfc in para:
            found.append((line_no, rfc, rfcs))
        para.clear()

    for i, line in enumerate(lines, 1):
        if not line.strip():
            flush()
            continue
        for m in CITATION.finditer(line):
            para.append((i, str(int(m.group(1)))))
    flush()
    return found


def scan(repo):
    """{relative path: [(line_no, rfc, paragraph_rfcs)]} across the tree."""
    cited = {}
    for rel in tracked_files(repo):
        if not is_scanned(rel):
            continue
        text = read_text(repo / rel)
        if text is None or "rfc" not in text.lower():
            continue
        hits = find_citations(text)
        if hits:
            cited[rel] = hits
    return cited


# --- the snapshot ------------------------------------------------------------

def load_snapshot(path):
    if not path.exists():
        return None
    return json.loads(path.read_text())


def _numbers(ids):
    """['RFC9110', 'rfc 9112'] -> ['9110', '9112']."""
    out = []
    for x in ids:
        m = CITATION.search(str(x)) or re.search(r"(\d{3,5})", str(x))
        if m:
            out.append(str(int(m.group(1))))
    return out


def entry_from_json(doc):
    """The snapshot's record of one RFC, from the RFC Editor's JSON."""
    return {
        "title": doc.get("title", ""),
        "status": doc.get("status", ""),
        "obsoleted_by": sorted(_numbers(doc.get("obsoleted_by") or []), key=int),
    }


def successors(rfcs, rfc, _seen=None):
    """The transitive closure of `obsoleted_by` from `rfc`, within `rfcs`."""
    seen = _seen if _seen is not None else set()
    for s in (rfcs.get(rfc) or {}).get("obsoleted_by", []):
        if s not in seen:
            seen.add(s)
            successors(rfcs, s, seen)
    return seen


# --- the rules (pure) --------------------------------------------------------

def check_citations(cited, snapshot):
    """Offline rules over the scan and the snapshot. Returns failure strings.

    1. Every cited RFC has a snapshot entry.
    2. A cited RFC with `obsoleted_by` is refused unless its paragraph names
       an RFC in its transitive successor set.
    3. Every snapshot entry is cited, or is a successor of something cited.
    4. Every successor a snapshot entry names has an entry of its own.
    """
    failures = []
    if snapshot is None:
        return [f"{SNAPSHOT_REL} is missing — {UPDATE_HINT}"]
    rfcs = snapshot.get("rfcs") or {}

    all_cited = set()
    for rel in sorted(cited):
        for line_no, rfc, para in cited[rel]:
            all_cited.add(rfc)
            where = f"{rel}:{line_no}"
            entry = rfcs.get(rfc)
            if entry is None:
                failures.append(
                    f"{where}: cites RFC {rfc}, which {SNAPSHOT_REL} has no "
                    f"entry for — {UPDATE_HINT}"
                )
                continue
            obs = entry.get("obsoleted_by") or []
            if not obs:
                continue
            if para & successors(rfcs, rfc):
                continue
            failures.append(
                f"{where}: cites RFC {rfc}, obsoleted by "
                + ", ".join(f"RFC {s}" for s in obs)
                + " — cite the successor, or name it in the same paragraph "
                "if the old document is the point"
            )

    reachable = set(all_cited)
    for rfc in all_cited:
        reachable |= successors(rfcs, rfc)
    for rfc in sorted(rfcs, key=int):
        if rfc not in reachable:
            failures.append(
                f"{SNAPSHOT_REL}: RFC {rfc} is recorded and nothing cites it "
                f"(nor anything it succeeds) — {UPDATE_HINT} to prune it"
            )
        for s in (rfcs[rfc] or {}).get("obsoleted_by", []):
            if s not in rfcs:
                failures.append(
                    f"{SNAPSHOT_REL}: RFC {rfc} is obsoleted by RFC {s}, "
                    f"which has no entry — {UPDATE_HINT}"
                )
    return failures


def check_workflow(text):
    """The monthly workflow exists, runs on a cron, and asks the RFC Editor."""
    if text is None:
        return [f"{WORKFLOW_REL} is missing — the live check runs nowhere"]
    failures = []
    if not re.search(r"^\s*-\s*cron:", text, re.M):
        failures.append(f"{WORKFLOW_REL}: no `cron:` schedule — it never runs unasked")
    if not re.search(r"check_citations\.py\s+--live\b", text):
        failures.append(
            f"{WORKFLOW_REL}: nothing runs `check_citations.py --live` — the "
            "snapshot is never compared with the RFC Editor"
        )
    return failures


def check_all(cited, snapshot, workflow_text):
    return check_citations(cited, snapshot) + check_workflow(workflow_text)


def check(repo=REPO):
    """What check_docs.py calls: the offline rules against the real tree."""
    return check_all(
        scan(repo),
        load_snapshot(repo / SNAPSHOT_REL),
        read_text(repo / WORKFLOW_REL),
    )


# --- the network half --------------------------------------------------------

def fetch_rfc(rfc, attempts=3):
    """The RFC Editor's JSON for one RFC, or None if it has no such document.

    Retries a transport failure with backoff; a persistent one raises,
    because the callers exist to ask and "could not ask" must not read as
    "nothing changed".
    """
    url = JSON_URL.format(n=rfc)
    last = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "mojo-http citation check"}
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            last = e
        except Exception as e:  # URLError, timeout, bad JSON
            last = e
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"could not fetch {url}: {last}")


def collect(rfcs_cited, fetch=fetch_rfc):
    """Snapshot entries for every cited RFC and, transitively, its successors.

    Returns (entries, unknown): `unknown` lists cited numbers the RFC Editor
    has no document for, which is a typo in the tree, not a snapshot entry.
    """
    entries, unknown = {}, []
    queue = sorted(set(rfcs_cited), key=int)
    while queue:
        rfc = queue.pop(0)
        if rfc in entries:
            continue
        doc = fetch(rfc)
        if doc is None:
            unknown.append(rfc)
            continue
        entries[rfc] = entry_from_json(doc)
        for s in entries[rfc]["obsoleted_by"]:
            if s not in entries:
                queue.append(s)
    return entries, unknown


def live_diff(snapshot, fetch=fetch_rfc):
    """Every snapshot entry against the RFC Editor now. Failure strings."""
    if snapshot is None:
        return [f"{SNAPSHOT_REL} is missing — {UPDATE_HINT}"]
    failures = []
    for rfc, entry in sorted((snapshot.get("rfcs") or {}).items(), key=lambda kv: int(kv[0])):
        try:
            doc = fetch(rfc)
        except Exception as e:
            failures.append(f"RFC {rfc}: could not ask the RFC Editor ({e})")
            continue
        if doc is None:
            failures.append(f"RFC {rfc}: the RFC Editor has no such document")
            continue
        now = entry_from_json(doc)
        if now["obsoleted_by"] != entry.get("obsoleted_by", []):
            failures.append(
                f"RFC {rfc}: the RFC Editor now says obsoleted by "
                f"{now['obsoleted_by'] or 'nothing'}; the snapshot says "
                f"{entry.get('obsoleted_by') or 'nothing'} — {UPDATE_HINT}, "
                "then re-point the citations"
            )
        elif now["status"] != entry.get("status"):
            failures.append(
                f"RFC {rfc}: status is now {now['status']!r}, the snapshot "
                f"says {entry.get('status')!r} — {UPDATE_HINT}"
            )
    return failures


def write_snapshot(path, entries):
    doc = {
        "_comment": (
            "Generated by scripts/check_citations.py --update from "
            + JSON_URL.format(n="<n>")
            + ". Every RFC the tree cites, plus its successors. Do not edit."
        ),
        "checked": date.today().isoformat(),
        "rfcs": {k: entries[k] for k in sorted(entries, key=int)},
    }
    path.write_text(json.dumps(doc, indent=2) + "\n")


def update(repo=REPO):
    cited = scan(repo)
    numbers = {rfc for hits in cited.values() for _, rfc, _ in hits}
    entries, unknown = collect(numbers)
    write_snapshot(repo / SNAPSHOT_REL, entries)
    print(f"{SNAPSHOT_REL}: {len(entries)} RFCs recorded ({len(numbers)} cited)")
    failures = [f"the RFC Editor has no RFC {n}, which the tree cites" for n in unknown]
    return failures + check_all(cited, load_snapshot(repo / SNAPSHOT_REL), read_text(repo / WORKFLOW_REL))


# --- selftest ----------------------------------------------------------------

def _snap(**rfcs):
    return {"rfcs": {k: {"title": k, "status": "x", "obsoleted_by": v} for k, v in rfcs.items()}}


def _ok_workflow():
    return "on:\n  schedule:\n    - cron: '0 0 * * 4'\nrun: python3 scripts/check_citations.py --live\n"


def selftest():
    fails = []

    def expect(label, problems, *needles):
        text = "\n".join(problems)
        for n in needles:
            if n not in text:
                fails.append(f"{label}: expected {n!r} in:\n{text or '(nothing)'}")

    def expect_clean(label, problems):
        if problems:
            fails.append(f"{label}: expected no failures, got:\n" + "\n".join(problems))

    # Scanning: paragraphs, line numbers, the spellings a citation takes.
    text = "per RFC 9110 §5.5\nand rfc9112 too\n\nsee RFC-6455\nhttps://www.rfc-editor.org/rfc/rfc07230.json\n"
    hits = find_citations(text)
    want = [(1, "9110", {"9110", "9112"}), (2, "9112", {"9110", "9112"}),
            (4, "6455", {"6455", "7230"}), (5, "7230", {"6455", "7230"})]
    if hits != want:
        fails.append(f"find_citations: got {hits}, want {want}")
    if find_citations("RFCs are fine; RFC12 is not a citation"):
        fails.append("find_citations: matched something that is not a citation")

    # Rule 2, and its null case.
    current = _snap(**{"9110": [], "9112": [], "7230": ["9110", "9112"]})
    chain = _snap(**{"9110": [], "9112": [], "7230": ["9110", "9112"], "2616": ["7230"]})
    expect("obsolete citation alone",
           check_citations({"a.md": [(3, "7230", {"7230"})]}, current),
           "a.md:3", "RFC 7230, obsoleted by RFC 9110, RFC 9112")
    expect_clean("obsolete citation beside its successor",
                 check_citations({"a.md": [(3, "7230", {"7230", "9112"}), (3, "9112", {"7230", "9112"})]}, current))
    expect_clean("obsolete citation beside a transitive successor",
                 check_citations({"a.md": [(3, "2616", {"2616", "9110"}), (3, "9110", {"2616", "9110"})]}, chain))
    expect("obsolete citation beside an unrelated RFC",
           check_citations({"a.md": [(3, "2616", {"2616", "6455"}), (3, "6455", {"2616", "6455"})]},
                           _snap(**{"2616": ["7230"], "7230": ["9110"], "9110": [], "6455": []})),
           "RFC 2616, obsoleted by RFC 7230")
    # Rule 1.
    expect("uncatalogued citation",
           check_citations({"a.md": [(1, "9457", {"9457"})]}, current),
           "a.md:1", "RFC 9457", "no entry")
    # Rule 3, and the null case: an uncited successor is not stale.
    expect("stale entry",
           check_citations({"a.md": [(1, "9110", {"9110"})]}, _snap(**{"9110": [], "6455": []})),
           "RFC 6455 is recorded and nothing cites it")
    expect_clean("uncited successor is reachable",
                 check_citations({"a.md": [(1, "2616", {"2616", "9110"}), (1, "9110", {"2616", "9110"})]}, chain))
    # Rule 4.
    expect("successor without an entry",
           check_citations({"a.md": [(1, "7230", {"7230", "9110"}), (1, "9110", {"7230", "9110"})]},
                           _snap(**{"7230": ["9110", "9112"], "9110": []})),
           "RFC 7230 is obsoleted by RFC 9112, which has no entry")
    expect("no snapshot", check_citations({}, None), "missing")

    # The workflow rule.
    expect_clean("workflow ok", check_workflow(_ok_workflow()))
    expect("workflow without cron", check_workflow(_ok_workflow().replace("cron", "corn")), "cron")
    expect("workflow without --live", check_workflow(_ok_workflow().replace("--live", "")), "--live")
    expect("workflow missing", check_workflow(None), "missing")

    # The RFC Editor's JSON shape, and the closure `collect` walks.
    docs = {
        "2616": {"title": "HTTP/1.1", "status": "DRAFT STANDARD", "obsoleted_by": ["RFC7230", "RFC7231"]},
        "7230": {"title": "Message Syntax", "status": "PROPOSED STANDARD", "obsoleted_by": ["RFC9110", "RFC9112"]},
        "7231": {"title": "Semantics", "status": "PROPOSED STANDARD", "obsoleted_by": ["RFC9110"]},
        "9110": {"title": "HTTP Semantics", "status": "INTERNET STANDARD", "obsoleted_by": []},
        "9112": {"title": "HTTP/1.1", "status": "INTERNET STANDARD", "obsoleted_by": []},
    }
    entries, unknown = collect({"2616", "99999"}, fetch=lambda n: docs.get(n))
    if set(entries) != set(docs) or unknown != ["99999"]:
        fails.append(f"collect: got {sorted(entries)} unknown={unknown}")
    if entries["2616"]["obsoleted_by"] != ["7230", "7231"]:
        fails.append(f"entry_from_json: {entries['2616']}")

    # The live comparison can report each way a document moves.
    snap = {"rfcs": entries}
    expect_clean("live: unchanged", live_diff(snap, fetch=lambda n: docs.get(n)))
    moved = dict(docs, **{"9112": dict(docs["9112"], obsoleted_by=["RFC9999"])})
    expect("live: newly obsoleted", live_diff(snap, fetch=lambda n: moved.get(n)),
           "RFC 9112: the RFC Editor now says obsoleted by ['9999']")
    expect("live: document gone", live_diff(snap, fetch=lambda n: None if n == "7231" else docs.get(n)),
           "RFC 7231: the RFC Editor has no such document")

    def flaky(n):
        raise RuntimeError("no route to host")
    expect("live: cannot ask", live_diff(snap, fetch=flaky), "could not ask")
    expect("live: no snapshot", live_diff(None, fetch=flaky), "missing")

    if fails:
        print("check_citations --selftest FAILED")
        for f in fails:
            print("  " + f)
        return 1
    print("check_citations --selftest OK")
    return 0


# --- sabotage ----------------------------------------------------------------

def _first_obsoleted(snapshot):
    for rfc in sorted(snapshot["rfcs"], key=int):
        if snapshot["rfcs"][rfc].get("obsoleted_by"):
            return rfc
    return None


def _first_uncited_successor(cited, snapshot):
    all_cited = {rfc for hits in cited.values() for _, rfc, _ in hits}
    for rfc in sorted(snapshot["rfcs"], key=int):
        if rfc not in all_cited:
            return rfc
    return None


def _deep(x):
    return json.loads(json.dumps(x))


def sabotage():
    """Revert each rule against the real tree; the checker must catch each."""
    cited = scan(REPO)
    snapshot = load_snapshot(SNAPSHOT)
    workflow = read_text(WORKFLOW)
    clean = check_all(cited, snapshot, workflow)
    if clean:
        print("the clean tree fails, so a sabotage would prove nothing:")
        for f in clean:
            print("  " + f)
        return 1
    first_file = sorted(cited)[0]
    first_cited = cited[first_file][0][1]

    def cite_obsolete(c, s, w):
        rfc = _first_obsoleted(s)
        if rfc is None:
            return None
        c = dict(c)
        c[first_file] = c[first_file] + [(999999, rfc, {rfc})]
        return c, s, w

    def drop_entry(c, s, w):
        s = _deep(s)
        del s["rfcs"][first_cited]
        return c, s, w

    def mark_obsolete(c, s, w):
        s = _deep(s)
        s["rfcs"][first_cited]["obsoleted_by"] = ["1"]
        return c, s, w

    def add_stray(c, s, w):
        s = _deep(s)
        s["rfcs"]["1"] = {"title": "stray", "status": "x", "obsoleted_by": []}
        return c, s, w

    def drop_successor(c, s, w):
        rfc = _first_uncited_successor(c, s)
        if rfc is None:
            return None
        s = _deep(s)
        del s["rfcs"][rfc]
        return c, s, w

    def no_snapshot(c, s, w):
        return c, None, w

    def no_cron(c, s, w):
        return c, s, re.sub(r"^\s*-\s*cron:.*\n", "", w, flags=re.M)

    def no_live(c, s, w):
        return c, s, w.replace("--live", "")

    def no_workflow(c, s, w):
        return c, s, None

    plan = [
        ("an obsoleted RFC is cited with no successor in the paragraph", cite_obsolete, "obsoleted by"),
        ("a cited RFC has no snapshot entry", drop_entry, "has no entry for"),
        ("the snapshot marks a cited RFC obsoleted", mark_obsolete, "obsoleted by"),
        ("the snapshot carries an entry nothing cites", add_stray, "nothing cites it"),
        ("a successor is missing from the snapshot", drop_successor, "which has no entry"),
        ("the snapshot is deleted", no_snapshot, "is missing"),
        ("the monthly workflow loses its cron", no_cron, "cron"),
        ("the monthly workflow stops passing --live", no_live, "--live"),
        ("the monthly workflow is deleted", no_workflow, "is missing"),
    ]
    ok = True
    for label, patch, must in plan:
        edited = patch(cited, snapshot, workflow)
        if edited is None or edited == (cited, snapshot, workflow):
            print(f"  NOT APPLICABLE  {label}\n     nothing in the tree matched the shape to sabotage")
            ok = False
            continue
        problems = check_all(*edited)
        if any(must in p for p in problems):
            print(f"  CAUGHT   {label}")
        else:
            ok = False
            print(f"  MISSED   {label}\n     expected {must!r}; got: {problems or 'nothing'}")
    print("check_citations --sabotage " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


# --- main --------------------------------------------------------------------

def main(argv):
    if "--selftest" in argv:
        return selftest()
    if "--sabotage" in argv:
        return sabotage()
    if "--update" in argv:
        failures = update()
    else:
        cited = scan(REPO)
        snapshot = load_snapshot(SNAPSHOT)
        failures = check_all(cited, snapshot, read_text(WORKFLOW))
        if "--live" in argv:
            failures += live_diff(snapshot)
        if not failures:
            n_rfcs = len({rfc for hits in cited.values() for _, rfc, _ in hits})
            print(
                f"citations: {n_rfcs} RFCs cited across {len(cited)} files, all "
                f"current (snapshot {snapshot.get('checked')}"
                + (", confirmed live" if "--live" in argv else "") + ")"
            )
    for f in failures:
        print("FAIL " + f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
