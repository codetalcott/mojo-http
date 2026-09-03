"""The documentation site, rendered from the tree's own pages.

    python3 scripts/docsite.py --out dist/site --base-url https://example.org
    python3 scripts/docsite.py --check        # link integrity, stdlib only
    python3 scripts/docsite.py --selftest     # the checks can fail

Discoverability work that does not touch the prose: README.md, QUICKSTART.md,
CHANGELOG.md, PROVENANCE.md and every page under docs/ are rendered to HTML
and served by m0serve itself (`poe serve-site`, `poe smoke-site`), which is
what gives them canonical URLs that search engines and agents can reach. The
site is a function of the tree -- there is no second copy of anything to
drift -- and PAGES below is the one place a page gets the title and the
one-line description that search results and `llms.txt` show, because those
are written for the question a reader typed, not the file's name.

What the built tree holds, and why each part is there:

- `/`, `/quickstart/`, `/docs/<page>/`: one `index.html` per page, so the
  static mount (which answers a directory URL with its `index.html`) serves
  them at clean URLs with no server-side routing.
- A Markdown twin beside every page (`/docs/spec.md` for `/docs/spec/`),
  advertised from the HTML by `<link rel="alternate" type="text/markdown">`.
  Agents fetch markdown better than they scrape HTML, and the twin's links
  point at other twins so an agent stays in markdown.
- `/llms.txt`: the repository's own `llms.txt` with its links made absolute,
  plus a generated index of every page. `/llms-full.txt`: every page's
  markdown in one file, for agents that want the whole corpus in one fetch.
- `/sitemap.xml` and `/robots.txt` for crawlers, `/spec.json` (the
  capability matrix, generated data) at a stable URL, and a `404.html` the
  fallback application (`apps/site`) serves for anything the mount lacks.

Two rules keep it honest. **Every relative link is resolved at build time,
and a link to nothing is a build failure**: a page in PAGES becomes its site
URL, any other file in the repository becomes its GitHub URL, and a fragment
must name a heading that exists (GitHub's slug rules, so `SPEC.md#known-...`
means the same thing here as on GitHub). And **every `docs/*.md` must be in
PAGES**, so a page cannot ship without a title -- the check is two closed
sets, the way the spec sheet's is.

`--check` and `--selftest` import only the standard library, so
`scripts/check_docs.py` runs the link check on doc-only pull requests (which
run no uv and no toolchain); only a full build needs `markdown-it-py`, which
is in the dev group. The rewriter is a fence-aware regex rather than a parser
so it can be stdlib; the full build then walks the parsed token stream and
refuses any relative link the regex missed, which is what keeps the two from
disagreeing quietly.
"""

import argparse
import datetime as _dt
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GITHUB = "https://github.com/codetalcott/mojo-http"
GITHUB_BLOB = GITHUB + "/blob/main/"
GITHUB_TREE = GITHUB + "/tree/main/"
PYPI = "https://pypi.org/project/m0serve/"
SITE_NAME = "m0serve"
DEFAULT_BASE = "http://localhost:8180"
AUTHOR = {"@type": "Person", "name": "Wm Talcott", "url": "https://github.com/codetalcott"}


class Page:
    """One rendered page: where it comes from, where it lives, what it is for."""

    def __init__(self, source, url, title, description, group, optional=False):
        self.source = source
        self.url = url
        self.title = title
        self.description = description
        self.group = group
        # llms.txt's `## Optional` tier: skip when context is short. These
        # pages stay on the site and in the sitemap; they leave llms-full.txt
        # and the primary index, so an agent's first read is the essentials.
        self.optional = optional
        # Set on the generated notes index; a page with no markdown source.
        self.body_html = None

    @property
    def md_url(self):
        """The markdown twin's path: `/docs/spec/` -> `/docs/spec.md`."""
        stem = self.url[:-1] if self.url.endswith("/") else self.url
        return (stem or "/index") + ".md"

    @property
    def out_html(self):
        return self.url.lstrip("/") + "index.html"


# The site's one editorial surface. Titles are written for the question a
# reader searched, not the file's name -- nobody searches for "m0serve";
# they search for the problem -- and descriptions are what a result page and
# llms.txt show under them. Groups follow docs/README.md's own grouping.
PAGES = [
    # Start here: the first screen, the tutorial, the operations reference,
    # the contract, the map.
    Page("apps/site/home.md", "/",
         "m0serve: SSE and WebSockets from plain sync Django and Flask views",
         "A WSGI/ASGI server written in Mojo. A synchronous view holds a "
         "Server-Sent Events stream or a WebSocket with two response headers "
         "and reaches every subscriber on every worker with one call. No "
         "Channels, no Redis, no daphne. pip install m0serve.",
         "Start here"),
    Page("QUICKSTART.md", "/quickstart/",
         "Django Server-Sent Events and WebSockets without Channels: a ten-minute quickstart",
         "From pip install to live multi-tab sync from one sync Django file. "
         "Every command is executed by CI on every pull request.",
         "Start here"),
    Page("docs/RUNNING.md", "/docs/running/",
         "Running m0serve: flags, execution modes, proxies and shutdown",
         "How to start the server for the application you have: which mode "
         "runs by default and why, every flag and when to reach for it, what "
         "to put in front of it, how it drains, and what each exit code means.",
         "Start here"),
    Page("docs/SPEC.md", "/docs/spec/",
         "m0serve capability matrix: what the server does and the CI gate that proves it",
         "One row per HTTP, WebSocket, WSGI, ASGI, security and deployment "
         "capability, each naming the test or CI step that proves it and the "
         "cadence it runs on. Also available as spec.json.",
         "Start here"),
    Page("docs/README.md", "/docs/",
         "m0serve documentation: every page, by what you are trying to do",
         "The map of the documentation grouped by intent: start here, "
         "understanding the design, measurements, the project record, and "
         "the Mojo framework underneath.",
         "Start here"),
    # Understanding the design.
    Page("docs/WSGI_VS_ASGI.md", "/docs/wsgi-vs-asgi/",
         "Why m0serve has two execution modes: WSGI, ASGI, free-threading and the cliffs in each",
         "What each mode is, why one would not do, what WSGI gets from a "
         "handler pool and held connections, what ASGI gets from the asyncio "
         "executor, what free-threading changes, and where each mode has a cliff.",
         "Understanding the design"),
    Page("docs/WSGI_CONFORMANCE.md", "/docs/wsgi-conformance/",
         "PEP 3333 conformance of m0serve, clause by clause",
         "Where the WSGI implementation stands against PEP 3333, clause by "
         "clause, and how the conformance is checked.",
         "Understanding the design"),
    Page("docs/ROADMAP.md", "/docs/roadmap/",
         "m0serve roadmap: milestones, known issues, and what is not planned",
         "The project's state on one page: the beta and 1.0 definitions, "
         "every known issue with what would retire it, what is deliberately "
         "not planned, and the index of design notes behind the decisions.",
         "Understanding the design"),
    # Measurements: records that age, kept with their environment.
    Page("docs/BENCHMARKS.md", "/docs/benchmarks/",
         "m0serve benchmarks: where it wins and loses against gunicorn, uvicorn and Granian",
         "How the benchmarks are run, what they compare, where m0serve loses "
         "and by how much, and the ways a benchmark of a server misleads.",
         "Measurements", optional=True),
    Page("docs/WSGI_PERFORMANCE.md", "/docs/wsgi-performance/",
         "m0serve vs gunicorn, uvicorn and Granian: WSGI and ASGI throughput and latency",
         "Requests per second and tail latency for the WSGI and ASGI paths "
         "against gunicorn, uvicorn and Granian, rendered from dated "
         "benchmark artifacts.",
         "Measurements", optional=True),
    Page("docs/SERVER_PERFORMANCE.md", "/docs/server-performance/",
         "The Mojo HTTP server's own numbers, without Python in the path",
         "Throughput and latency of the Mojo server serving Mojo handlers, "
         "with the environment each number was taken in.",
         "Measurements", optional=True),
    Page("docs/REAL_APP_VALIDATION.md", "/docs/real-app-validation/",
         "m0serve against real Django applications: the soak record",
         "The server run against Django projects nobody here wrote, with "
         "what broke, what was measured and what changed as a result. A 1.0 "
         "requirement.",
         "Measurements", optional=True),
    # The project record.
    Page("README.md", "/readme/",
         "The mojo-http README: the whole repository, Mojo framework included",
         "The repository's own README: the realtime server, its install "
         "matrix and limits, and the Mojo web framework, Datastar adapter and "
         "SQLite bindings m0serve is one package of.",
         "The project", optional=True),
    Page("CHANGELOG.md", "/changelog/",
         "m0serve changelog",
         "Notable changes to mojo-http and the m0serve wheel, by version, in "
         "Keep a Changelog form.",
         "The project", optional=True),
    Page("docs/RELEASING.md", "/docs/releasing/",
         "How an m0serve release happens",
         "The release path for the m0serve wheel: the gates CI runs, the two "
         "pre-release gates it structurally cannot, and the order.",
         "The project", optional=True),
    Page("PROVENANCE.md", "/provenance/",
         "Where mojo-http came from: provenance and licensing",
         "The repository's origin as an extraction from a private monorepo, "
         "the forked HTTP server inside it, and the licensing record.",
         "The project", optional=True),
    # The Mojo framework, for people building on it directly.
    Page("docs/FFI_DISTRIBUTION.md", "/docs/ffi-distribution/",
         "The m0-core C-ABI bundle: what ships and the licensing position",
         "What the shared library built from m0-core contains, how a foreign "
         "caller loads it, and the licensing position of the bundle.",
         "The Mojo framework", optional=True),
    Page("docs/SQLITE_PERFORMANCE.md", "/docs/sqlite-performance/",
         "m0-sqlite performance findings: batched writes, mmap_size, json_each",
         "Measured findings for SQLite from Mojo: transactions around batch "
         "writes, mmap_size for large random reads, json_each for IN lists.",
         "The Mojo framework", optional=True),
    Page("docs/sqlite-vtab-feasibility.md", "/docs/sqlite-vtab-feasibility/",
         "SQLite virtual tables from Mojo: a feasibility record",
         "Whether SQLite virtual tables are reachable from Mojo through the "
         "m0-sqlite bindings, and what was tried.",
         "The Mojo framework", optional=True),
]

NOTES_DIR = "docs/notes"
NOTES_GROUP = "Design notes"
NOTES_INDEX_URL = "/notes/"

# Files that are copied into the site rather than rendered, so a link to
# them resolves to the served copy rather than to GitHub.
ASSETS = {
    "docs/spec.json": "/spec.json",
}

# Paths that the site GENERATES at the root; a page linking to the source
# file lands on the served one.
GENERATED = {
    "llms.txt": "/llms.txt",
}

_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
# `](target)` alone, not the whole `[text](target)`: link text wraps across
# lines in this corpus, and a regex that needs the opening bracket on the
# same line misses every such link (QUICKSTART's `apps/django_realtime/`
# did; the parser-side refusal in `_refuse_relative` is what caught it).
_INLINE_LINK = re.compile(r"(\]\()([^()\s]+|<[^>]*>)((?:\s+\"[^\"]*\")?\))")
_REF_DEF = re.compile(r"^(\[[^\]]+\]:\s*)(\S+)(.*)$")
_CODE_SPAN = re.compile(r"`+[^`]*`+")
_HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
_FENCE = re.compile(r"^(\s{0,3})(`{3,}|~{3,})")


def read_version(repo):
    m = re.search(r'^version = "([^"]+)"', (repo / "pyproject.toml").read_text(), re.M)
    return m.group(1) if m else "0.0.0"


def fenced(lines):
    """Yield (line, inside_fence) so link rewriting can skip code blocks."""
    fence = None
    for line in lines:
        m = _FENCE.match(line)
        if fence is None and m:
            fence = m.group(2)[0]
            yield line, True
            continue
        if fence is not None and m and m.group(2)[0] == fence and len(m.group(2)) >= 3:
            fence = None
            yield line, True
            continue
        yield line, fence is not None


def heading_plain(text):
    """The text GitHub slugs: code spans as their content, emphasis and link
    syntax stripped, underscores kept (`M0_WORKERS` slugs to `m0_workers`)."""
    text = text.strip().rstrip("#").strip()
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.replace("`", "").replace("**", "").replace("*", "")
    text = text.replace("\\|", "|")
    return text


def slugify(text):
    """GitHub's heading slug: lowercase, drop anything but word characters,
    spaces and hyphens, spaces to hyphens."""
    s = heading_plain(text).lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def headings(md):
    """(level, text, slug) for every ATX heading outside a fence, slugs
    de-duplicated the way GitHub does (`-1`, `-2`, ...)."""
    out, seen = [], {}
    for line, in_code in fenced(md.splitlines()):
        if in_code:
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if not m:
            continue
        slug = slugify(m.group(2))
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        if n:
            slug = f"{slug}-{n}"
        out.append((len(m.group(1)), heading_plain(m.group(2)), slug))
    return out


def _first_paragraph(md):
    """The first prose paragraph after the H1, as one plain line: not a
    heading, a blockquote, a list, a fence or a table."""
    text = _HTML_COMMENT.sub("", md)
    paras, cur, in_code = [], [], False
    for line in text.splitlines():
        if _FENCE.match(line):
            in_code = not in_code
            continue
        if in_code:
            continue
        if line.strip() == "":
            if cur:
                paras.append(" ".join(cur)); cur = []
            continue
        if line.lstrip().startswith(("#", ">", "-", "*", "|", "```")) or re.match(r"^\s*\d+\. ", line):
            if cur:
                paras.append(" ".join(cur)); cur = []
            continue
        cur.append(line.strip())
    if cur:
        paras.append(" ".join(cur))
    for para in paras:
        plain = heading_plain(re.sub(r"\s+", " ", para))
        if len(plain) > 40:
            return plain[:220].rsplit(" ", 1)[0] + ("…" if len(plain) > 220 else "")
    return ""


def strip_comments(md):
    """Drop HTML comments outside fences. The doc-fact ratchet's
    `<!-- num:... -->` spans are inline, and with raw HTML disabled in the
    renderer they would otherwise print as text."""
    out = []
    for line, in_code in fenced(md.splitlines()):
        out.append(line if in_code else _HTML_COMMENT.sub("", line))
    return "\n".join(out) + "\n"


def git_dates(repo, rel):
    """(first commit, last commit) ISO dates for a file; today if unknown."""
    def one(args):
        try:
            r = subprocess.run(["git", "-C", str(repo), "log", *args, "--", rel],
                               capture_output=True, text=True, timeout=30)
            lines = [l for l in r.stdout.splitlines() if l.strip()]
            return lines
        except (OSError, subprocess.SubprocessError):
            return []
    today = _dt.date.today().isoformat()
    last = one(["-1", "--format=%cs"])
    first = one(["--diff-filter=A", "--format=%cs", "--follow"])
    return (first[-1] if first else today), (last[0] if last else today)


class Site:
    def __init__(self, repo, base=DEFAULT_BASE, pages=None, assets=None, generated=None):
        self.repo = Path(repo)
        self.base = base.rstrip("/")
        self.pages = list(PAGES if pages is None else pages)
        self.assets = dict(ASSETS if assets is None else assets)
        self.generated = dict(GENERATED if generated is None else generated)
        self.notes = self._discover_notes()
        self.pages += self.notes
        self.by_source = {p.source: p for p in self.pages}
        self._headings = {}

    def _discover_notes(self):
        """`docs/notes/*.md`, each a page under /notes/ with its H1 as the
        title and its first paragraph as the description -- no PAGES entry
        needed, because a note's title IS its heading. The index page at
        /notes/ is generated, and is the only entry the sidebar shows."""
        out = []
        d = self.repo / NOTES_DIR
        if not d.is_dir():
            return out
        for f in sorted(d.glob("*.md")):
            text = f.read_text()
            m = re.search(r"^# (.+)$", text, re.M)
            title = heading_plain(m.group(1)) if m else f.stem
            desc = _first_paragraph(text) or title
            out.append(Page(f.relative_to(self.repo).as_posix(), f"/notes/{f.stem}/",
                            title, desc, NOTES_GROUP, optional=True))
        return out

    # -- resolution ---------------------------------------------------------

    def headings_of(self, source):
        if source not in self._headings:
            self._headings[source] = headings((self.repo / source).read_text())
        return self._headings[source]

    def slugs_of(self, source):
        return {slug for _, _, slug in self.headings_of(source)}

    def page_url(self, page, flavor):
        return self.base + (page.md_url if flavor == "md" else page.url)

    def resolve(self, source, target, flavor, problems):
        """One link target as written in `source` -> the URL to emit."""
        raw = target
        if target.startswith("<") and target.endswith(">"):
            target = target[1:-1]
        if target.startswith("#"):
            if target[1:] not in self.slugs_of(source):
                problems.append(f"{source}: link to {raw!r} names no heading in the page")
            return raw
        if _SCHEME.match(target):
            if target.startswith(GITHUB_BLOB):
                rel, _, frag = target[len(GITHUB_BLOB):].partition("#")
                if rel in self.by_source:
                    return self._page_link(source, self.by_source[rel], frag, flavor, problems)
            return raw
        path, _, frag = target.partition("#")
        rel = os.path.normpath(os.path.join(os.path.dirname(source), path))
        if rel == ".":
            rel = ""
        if rel.startswith(".."):
            problems.append(f"{source}: link {raw!r} escapes the repository")
            return raw
        if rel in self.by_source:
            return self._page_link(source, self.by_source[rel], frag, flavor, problems)
        if rel in self.assets:
            return self.base + self.assets[rel]
        if rel in self.generated:
            return self.base + self.generated[rel]
        fs = self.repo / rel
        if fs.is_dir():
            return GITHUB_TREE + rel.rstrip("/") + ("/" if rel else "")
        if fs.is_file():
            return GITHUB_BLOB + rel + ("#" + frag if frag else "")
        problems.append(f"{source}: link {raw!r} resolves to {rel or '/'}, which does not exist")
        return raw

    def _page_link(self, source, page, frag, flavor, problems):
        if frag and frag not in self.slugs_of(page.source):
            problems.append(
                f"{source}: link to {page.source}#{frag} names no heading in that page"
            )
        return self.page_url(page, flavor) + ("#" + frag if frag else "")

    def rewrite(self, source, md, flavor, problems):
        """Every link in `md` made absolute, code left alone."""
        out = []
        for line, in_code in fenced(md.splitlines()):
            if in_code:
                out.append(line)
                continue
            m = _REF_DEF.match(line)
            if m:
                out.append(m.group(1) + self.resolve(source, m.group(2), flavor, problems) + m.group(3))
                continue
            pieces, pos = [], 0
            for span in _CODE_SPAN.finditer(line):
                pieces.append(self._rewrite_segment(source, line[pos:span.start()], flavor, problems))
                pieces.append(span.group(0))
                pos = span.end()
            pieces.append(self._rewrite_segment(source, line[pos:], flavor, problems))
            out.append("".join(pieces))
        return "\n".join(out) + ("\n" if md.endswith("\n") else "")

    def _rewrite_segment(self, source, text, flavor, problems):
        return _INLINE_LINK.sub(
            lambda m: m.group(1) + self.resolve(source, m.group(2), flavor, problems) + m.group(3),
            text,
        )

    # -- the check ----------------------------------------------------------

    def check(self):
        problems = []
        for p in self.pages:
            if not (self.repo / p.source).is_file():
                problems.append(f"PAGES names {p.source}, which does not exist")
            if not p.title or not p.description:
                problems.append(f"{p.source}: PAGES gives it no title or no description")
        docs = self.repo / "docs"
        if docs.is_dir():
            for f in sorted(docs.glob("*.md")):
                rel = f.relative_to(self.repo).as_posix()
                if rel not in self.by_source:
                    problems.append(
                        f"{rel} is not in scripts/docsite.py's PAGES — every docs/*.md "
                        "is rendered, and a page needs a title and a description to be"
                    )
        for rel in self.assets:
            if not (self.repo / rel).is_file():
                problems.append(f"ASSETS names {rel}, which does not exist")
        for p in self.notes:
            if not re.search(r"^# .+$", (self.repo / p.source).read_text(), re.M):
                problems.append(f"{p.source}: a design note needs an H1; it is the page's title")
        if problems:
            return problems
        for p in self.pages:
            md = (self.repo / p.source).read_text()
            self.rewrite(p.source, md, "html", problems)
        llms = self.repo / "llms.txt"
        if llms.is_file():
            self.rewrite("llms.txt", llms.read_text(), "md", problems)
        else:
            problems.append("llms.txt is missing from the repository root")
        return problems

    # -- the build ----------------------------------------------------------

    def build(self, out):
        problems = self.check()
        if problems:
            raise SystemExit("docsite: the tree does not build:\n  - " + "\n  - ".join(problems))
        from markdown_it import MarkdownIt  # the one non-stdlib import, build only

        out = Path(out)
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        version = read_version(self.repo)
        md_parser = MarkdownIt("commonmark", {"html": False, "linkify": False}).enable(
            ["table", "strikethrough"]
        )
        entries = []
        omitted = [p for p in self.pages if p.optional]
        full = [f"# {SITE_NAME} — the essential documentation in one file\n\n"
                f"> The pages an agent needs first, as Markdown, in reading order; each\n"
                f"> page's own URL is on the comment line that opens it. The measurements,\n"
                f"> the project record, the Mojo framework pages and the design notes are\n"
                f"> omitted here on purpose ({len(omitted)} pages); {self.base}/llms.txt indexes\n"
                f"> every one of them under `## Optional`, each with a Markdown URL.\n"]
        for p in self.pages:
            src = strip_comments((self.repo / p.source).read_text())
            src = self._with_lede(p, src)
            first, last = git_dates(self.repo, p.source)
            html_md = self.rewrite(p.source, src, "html", [])
            twin_md = self.rewrite(p.source, src, "md", [])
            tokens = md_parser.parse(html_md)
            self._refuse_relative(p, tokens)
            hs = headings(html_md)
            slugs = [slug for _, _, slug in hs]
            body = self._render(md_parser, tokens, slugs, p)
            body = self._with_toc(body, hs)
            page_html = self._template(p, body, version, first, last)
            dest = out / p.out_html
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(page_html)
            (out / p.md_url.lstrip("/")).write_text(twin_md)
            entries.append((p, last))
            if not p.optional:
                full.append(f"\n\n<!-- {self.page_url(p, 'md')} -->\n\n{twin_md.rstrip()}\n")
        # The design-notes index: generated, the one notes entry the sidebar shows.
        if self.notes:
            idx = Page("", NOTES_INDEX_URL,
                       "m0serve design notes: the engineering record behind the decisions",
                       "Long-form, dated notes on what was built and measured, what was "
                       "refused and why, and the post-mortems, kept as written.",
                       NOTES_GROUP, optional=True)
            items = "".join(
                f'<li><a href="{self.page_url(n, "html")}">{html.escape(n.title)}</a>'
                f"<p>{html.escape(n.description)}</p></li>" for n in self.notes)
            body = (f"<h1>Design notes</h1><p class=\"lede\">{html.escape(idx.description)}</p>"
                    f"<ul class=\"index\">{items}</ul>")
            (out / "notes").mkdir(parents=True, exist_ok=True)
            (out / "notes" / "index.html").write_text(self._template(idx, body, version, None, None, is_index=True))
            (out / "notes.md").write_text(
                f"# Design notes\n\n{idx.description}\n\n"
                + "".join(f"- [{n.title}]({self.page_url(n, 'md')}): {n.description}\n" for n in self.notes))
            entries.append((idx, _dt.date.today().isoformat()))
        for rel, url in self.assets.items():
            shutil.copyfile(self.repo / rel, out / url.lstrip("/"))
        (out / "llms.txt").write_text(self._llms())
        (out / "llms-full.txt").write_text("".join(full))
        (out / "sitemap.xml").write_text(self._sitemap(entries))
        (out / "robots.txt").write_text(self._robots())
        (out / "404.html").write_text(self._template(
            Page("", "/404.html", "Not found", "There is no page at this address.", ""),
            "<h1>Not found</h1><p>There is no page at this address. The "
            f"<a href=\"{self.base}/\">front page</a> and <a href=\"{self.base}/docs/\">the "
            "documentation map</a> list every page.</p>",
            version, None, None, noindex=True))
        return len(entries)

    def _with_lede(self, page, md):
        """One orienting sentence under the title, as a blockquote right after
        the H1, in the HTML and the Markdown twin alike -- the description a
        search result shows, so the page and its listing say the same thing.
        Notes skip it: their provenance blockquote is already there."""
        if page.group == NOTES_GROUP or not page.description or page.url == "/":
            return md  # the home page's first line IS its pitch
        m = re.search(r"^# .+\n", md, re.M)
        if not m:
            return md
        return md[:m.end()] + "\n> " + page.description + "\n" + md[m.end():]

    def _with_toc(self, body, hs):
        """An "On this page" list for long pages: every h2 and h3, linked to
        the ids `_render` assigned. Inserted after the lede so the first
        screen is title, one sentence, then the map."""
        entries = [(lvl, text, slug) for lvl, text, slug in hs if lvl in (2, 3)]
        if len(entries) < 6:
            return body
        items = "".join(
            f'<li class="l{lvl}"><a href="#{slug}">{html.escape(text)}</a></li>'
            for lvl, text, slug in entries)
        toc = f'<nav class="toc" aria-label="On this page"><p>On this page</p><ul>{items}</ul></nav>'
        h1_end = body.find("</h1>")
        if h1_end < 0:
            return toc + body
        cut = h1_end + len("</h1>")
        nxt_h2 = body.find("<h2", cut)
        bq = body.find("</blockquote>", cut)
        if 0 <= bq and (nxt_h2 < 0 or bq < nxt_h2):
            cut = bq + len("</blockquote>")
        return body[:cut] + "\n" + toc + body[cut:]

    def _refuse_relative(self, page, tokens):
        """The regex rewriter must have made every link absolute; the parser
        is the check on it."""
        def walk(ts):
            for t in ts:
                if t.type in ("link_open", "image"):
                    href = t.attrGet("href" if t.type == "link_open" else "src") or ""
                    if not (_SCHEME.match(href) or href.startswith("#")):
                        raise SystemExit(
                            f"docsite: {page.source} still carries the relative link "
                            f"{href!r} after rewriting — the rewriter missed a shape "
                            "the parser sees"
                        )
                if t.children:
                    walk(t.children)
        walk(tokens)

    def _render(self, parser, tokens, slugs, page):
        n = sum(1 for t in tokens if t.type == "heading_open")
        if n != len(slugs):
            raise SystemExit(
                f"docsite: {page.source}: the parser sees {n} headings and the "
                f"slugger {len(slugs)} — a heading shape headings() does not read"
            )
        i = 0
        for t in tokens:
            if t.type == "heading_open":
                t.attrSet("id", slugs[i])
                i += 1
            elif t.type == "table_open":
                t.attrSet("class", "tbl")
        body = parser.renderer.render(tokens, parser.options, {})
        body = body.replace('<table class="tbl">', '<div class="table-wrap"><table>')
        body = body.replace("</table>", "</table></div>")
        return body

    # -- outputs ------------------------------------------------------------

    def _llms(self):
        src = (self.repo / "llms.txt").read_text().rstrip()
        text = self.rewrite("llms.txt", src, "md", [])
        essential = [p for p in self.pages if not p.optional]
        rest = [p for p in self.pages if p.optional]
        lines = [text, "", "## Documentation", "",
                 f"Every page of {self.base}/ has a Markdown twin at the URL below; the",
                 "same text rendered is at the URL without `.md` (with a trailing `/`).",
                 f"[llms-full.txt]({self.base}/llms-full.txt) is these pages in one file.", ""]
        for p in essential:
            lines.append(f"- [{p.title}]({self.page_url(p, 'md')}): {p.description}")
        lines += ["", "## Machine-readable", "",
                  f"- [spec.json]({self.base}/spec.json): the capability matrix as JSON, "
                  "generated from SPEC.md",
                  f"- [sitemap.xml]({self.base}/sitemap.xml)",
                  f"- [Source repository]({GITHUB}) · [PyPI]({PYPI})", "",
                  "## Optional", "",
                  "Measurements, the project record, the Mojo framework underneath, and the",
                  "design notes: read when the question needs them, skip when context is short.", ""]
        group = None
        for p in rest:
            if p.group != group:
                group = p.group
                lines.append(f"- **{group}**")
            lines.append(f"  - [{p.title}]({self.page_url(p, 'md')}): {p.description}")
        return "\n".join(lines) + "\n"

    def _sitemap(self, entries):
        rows = "".join(
            f"  <url><loc>{html.escape(self.page_url(p, 'html'))}</loc>"
            f"<lastmod>{last}</lastmod></url>\n"
            for p, last in entries
        )
        return ('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                f"{rows}</urlset>\n")

    def _robots(self):
        return ("# Public documentation. Crawlers and AI agents are welcome.\n"
                "# Agents: start at /llms.txt (an index with one-line descriptions)\n"
                "# or /llms-full.txt (every page as Markdown, in one file).\n"
                "User-agent: *\n"
                "Allow: /\n"
                f"Sitemap: {self.base}/sitemap.xml\n")

    def _jsonld(self, page, version, first, last):
        if page.url == "/":
            data = {
                "@context": "https://schema.org",
                "@type": "SoftwareApplication",
                "name": SITE_NAME,
                "description": page.description,
                "url": self.base + "/",
                "applicationCategory": "DeveloperApplication",
                "operatingSystem": "macOS, Linux",
                "softwareVersion": version,
                "installUrl": PYPI,
                "sameAs": [GITHUB, PYPI],
                "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
                "author": AUTHOR,
                "license": GITHUB_BLOB + "LICENSE",
            }
        else:
            data = {
                "@context": "https://schema.org",
                "@type": "TechArticle",
                "headline": page.title,
                "description": page.description,
                "url": self.page_url(page, "html"),
                "datePublished": first,
                "dateModified": last,
                "author": AUTHOR,
                "isPartOf": {"@type": "WebSite", "name": SITE_NAME, "url": self.base + "/"},
                "about": {"@type": "SoftwareApplication", "name": SITE_NAME},
            }
        return json.dumps(data, ensure_ascii=False, indent=1).replace("</", "<\\/")

    def _nav(self, current):
        groups = {}
        for p in self.pages:
            if p.group == NOTES_GROUP:
                continue
            groups.setdefault(p.group, []).append(p)
        parts = []
        for g, ps in groups.items():
            items = "".join(
                f'<li><a href="{self.page_url(p, "html")}"'
                + (' aria-current="page"' if p is current else "")
                + f'>{html.escape(p.title.split(":")[0])}</a></li>'
                for p in ps
            )
            if g == "Understanding the design" and self.notes:
                cur = ' aria-current="page"' if current.group == NOTES_GROUP else ""
                items += (f'<li><a href="{self.base}{NOTES_INDEX_URL}"{cur}>Design notes'
                          f' <span class="n">{len(self.notes)}</span></a></li>')
            parts.append(f"<section><h2>{html.escape(g)}</h2><ul>{items}</ul></section>")
        return "".join(parts)

    def _template(self, page, body, version, first, last, noindex=False, is_index=False):
        canonical = self.base + page.url
        esc = html.escape
        alternate = (f'<link rel="alternate" type="text/markdown" href="{esc(self.base + page.md_url)}" '
                     f'title="This page as Markdown">' if (page.source or is_index) else "")
        jsonld = (f'<script type="application/ld+json">{self._jsonld(page, version, first, last)}</script>'
                  if page.source else "")
        robots = '<meta name="robots" content="noindex">' if noindex else ""
        source_link = (f'<a href="{GITHUB_BLOB}{page.source}">Source on GitHub</a> · '
                       f'<a href="{esc(self.base + page.md_url)}">This page as Markdown</a> · '
                       if page.source else
                       (f'<a href="{esc(self.base + page.md_url)}">This page as Markdown</a> · ' if is_index else ""))
        return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(page.title)}</title>
<meta name="description" content="{esc(page.description)}">
<link rel="canonical" href="{esc(canonical)}">
{alternate}
{robots}
<meta property="og:site_name" content="{SITE_NAME}">
<meta property="og:type" content="{'website' if page.url == '/' else 'article'}">
<meta property="og:title" content="{esc(page.title)}">
<meta property="og:description" content="{esc(page.description)}">
<meta property="og:url" content="{esc(canonical)}">
<meta name="twitter:card" content="summary">
<meta name="generator" content="mojo-http scripts/docsite.py">
{jsonld}
<style>{CSS}</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="top">
  <a class="brand" href="{self.base}/">{SITE_NAME}</a>
  <span class="tag">Realtime from a synchronous Python app</span>
  <nav aria-label="Site">
    <a href="{self.base}/quickstart/">Quickstart</a>
    <a href="{self.base}/docs/">Docs</a>
    <a href="{self.base}/docs/spec/">Capabilities</a>
    <a href="{self.base}/changelog/">Changelog</a>
    <a href="{GITHUB}" rel="noopener">GitHub</a>
    <a href="{PYPI}" rel="noopener">PyPI</a>
  </nav>
</header>
<div class="layout">
<nav class="side" aria-label="Pages">{self._nav(page)}</nav>
<main id="main"><article>
{body}
</article>
<footer>
  <p>{source_link}<a href="{self.base}/llms.txt">llms.txt</a> · <a href="{self.base}/sitemap.xml">Sitemap</a></p>
  <p>{SITE_NAME} {esc(version)} · <a href="{GITHUB}/blob/main/LICENSE">License</a> · Built from the repository's own pages by <code>scripts/docsite.py</code>; served by m0serve.</p>
</footer>
</main>
</div>
</body>
</html>
"""


CSS = """
:root{--bg:#fdfcfa;--fg:#1f2328;--muted:#59636e;--line:#e3e1dc;--accent:#8a3b12;--code:#f3f1ec;--nav:#f7f5f1}
@media (prefers-color-scheme:dark){:root{--bg:#15171a;--fg:#e6e6e3;--muted:#9aa3ad;--line:#2d3138;--accent:#f0a06a;--code:#1e2126;--nav:#1a1d21}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
a{color:var(--accent)}a:hover{text-decoration-thickness:2px}
.skip{position:absolute;left:-999px}.skip:focus{left:8px;top:8px;background:var(--bg);padding:.5rem;z-index:9}
.top{display:flex;flex-wrap:wrap;gap:.5rem 1.25rem;align-items:baseline;padding:.9rem 1.25rem;border-bottom:1px solid var(--line)}
.brand{font-weight:700;font-size:1.15rem;text-decoration:none;color:var(--fg)}
.tag{color:var(--muted);font-size:.9rem;flex:1 1 auto}
.top nav{display:flex;flex-wrap:wrap;gap:1rem;font-size:.95rem}.top nav a{text-decoration:none;color:var(--fg)}.top nav a:hover{color:var(--accent)}
.layout{display:grid;grid-template-columns:minmax(0,1fr);max-width:80rem;margin:0 auto}
@media (min-width:64rem){.layout{grid-template-columns:16rem minmax(0,1fr)}}
.side{padding:1.25rem;border-right:1px solid var(--line);background:var(--nav);font-size:.9rem}
.side h2{font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:1.1rem 0 .4rem}.side h2:first-child{margin-top:0}
.side ul{list-style:none;margin:0;padding:0}.side li{margin:.2rem 0}.side a{text-decoration:none;color:var(--fg)}.side a:hover{color:var(--accent)}.side a[aria-current]{color:var(--accent);font-weight:600}
main{padding:1.5rem 1.25rem 3rem;min-width:0}article{max-width:48rem}
h1{font-size:1.9rem;line-height:1.2;margin:.2rem 0 1rem}h2{font-size:1.4rem;margin-top:2.2rem;padding-top:.4rem;border-top:1px solid var(--line)}h3{font-size:1.12rem;margin-top:1.8rem}h4{font-size:1rem}
h1,h2,h3,h4{scroll-margin-top:1rem}h2 a,h3 a{color:inherit}
pre{background:var(--code);padding:.85rem 1rem;overflow-x:auto;border-radius:6px;font-size:.86rem;line-height:1.5}
code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.92em}:not(pre)>code{background:var(--code);padding:.1em .3em;border-radius:4px}
blockquote{margin:1rem 0;padding:.1rem 1rem;border-left:3px solid var(--accent);color:var(--muted)}
h1+blockquote,.lede{font-size:1.08rem;color:var(--muted);border-left:0;padding:0;margin:-.4rem 0 1.2rem}
.toc{margin:0 0 1.6rem;padding:.7rem 1rem;background:var(--nav);border:1px solid var(--line);border-radius:6px;font-size:.9rem}
.toc p{margin:0 0 .3rem;font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
.toc ul{margin:0;padding:0;list-style:none;columns:2;column-gap:1.5rem}.toc li{margin:.15rem 0;break-inside:avoid}.toc li.l3{padding-left:1rem;font-size:.85rem}.toc a{text-decoration:none}.toc a:hover{text-decoration:underline}
@media (max-width:40rem){.toc ul{columns:1}}
ul.index{list-style:none;padding:0}ul.index li{margin:0 0 1rem}ul.index p{margin:.15rem 0 0;color:var(--muted);font-size:.9rem}
.side .n{color:var(--muted);font-size:.75rem;margin-left:.3rem}
.table-wrap{overflow-x:auto;margin:1rem 0}table{border-collapse:collapse;font-size:.9rem;min-width:100%}th,td{border:1px solid var(--line);padding:.4rem .6rem;text-align:left;vertical-align:top}th{background:var(--code)}
img{max-width:100%}hr{border:0;border-top:1px solid var(--line);margin:2rem 0}
footer{margin-top:3rem;padding-top:1rem;border-top:1px solid var(--line);color:var(--muted);font-size:.85rem}
"""


# -- selftest -----------------------------------------------------------------

def _fake_repo(root, extra_docs=None, readme_links="", llms_links=""):
    (root / "docs").mkdir(parents=True)
    (root / "pyproject.toml").write_text('version = "9.9.9"\n')
    (root / "README.md").write_text(
        "# Hello\n\nSee [the spec](docs/SPEC.md#rows) and [the map](docs/README.md).\n"
        "A [source file](scripts/x.py) and `a [code](nowhere.md) span`.\n"
        "```\n[fenced](nowhere.md)\n```\n" + readme_links
    )
    (root / "docs" / "SPEC.md").write_text("# Spec\n\n## Rows\n\ntext [up](../README.md)\n")
    (root / "docs" / "README.md").write_text("# Map\n\n[spec](SPEC.md)\n")
    (root / "scripts").mkdir()
    (root / "scripts" / "x.py").write_text("")
    (root / "llms.txt").write_text("# t\n\n- [readme](README.md)\n" + llms_links)
    for name, text in (extra_docs or {}).items():
        (root / "docs" / name).write_text(text)
    return [
        Page("README.md", "/", "Home", "d", "g"),
        Page("docs/SPEC.md", "/docs/spec/", "Spec", "d", "g"),
        Page("docs/README.md", "/docs/", "Map", "d", "g"),
    ]


def selftest():
    """The checks can report failure, and the rewriter leaves code alone."""
    failures = []

    def expect(name, problems, needle):
        hit = any(needle in p for p in problems)
        if not hit:
            failures.append(f"{name}: expected a problem mentioning {needle!r}, got {problems}")

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pages = _fake_repo(root)
        site = Site(root, "https://s.example", pages, assets={}, generated={})
        problems = site.check()
        if problems:
            failures.append(f"clean corpus: expected no problems, got {problems}")
        out = site.rewrite("README.md", (root / "README.md").read_text(), "html", [])
        if "https://s.example/docs/spec/#rows" not in out:
            failures.append(f"page link not rewritten: {out!r}")
        if GITHUB_BLOB + "scripts/x.py" not in out:
            failures.append(f"repo file link not sent to GitHub: {out!r}")
        if out.count("nowhere.md") != 2:
            failures.append(f"a link inside code was rewritten: {out!r}")
        twin = site.rewrite("README.md", (root / "README.md").read_text(), "md", [])
        if "https://s.example/docs/spec.md#rows" not in twin:
            failures.append(f"markdown flavor does not link twins: {twin!r}")
        if slugify("`M0_WORKERS` and friends: a (test)?") != "m0_workers-and-friends-a-test":
            failures.append(f"slugify drifted from GitHub: {slugify('`M0_WORKERS` and friends: a (test)?')!r}")
        hs = headings("# A\n\n## Same\n\n## Same\n\n```\n# not one\n```\n")
        if [s for _, _, s in hs] != ["a", "same", "same-1"]:
            failures.append(f"heading slugs: {hs}")

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pages = _fake_repo(root, readme_links="[gone](docs/MISSING.md)\n")
        expect("broken link", Site(root, "https://s.example", pages, {}, {}).check(), "does not exist")

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pages = _fake_repo(root, readme_links="[frag](docs/SPEC.md#no-such-heading)\n")
        expect("missing fragment", Site(root, "https://s.example", pages, {}, {}).check(), "names no heading")

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pages = _fake_repo(root, readme_links="[self](#nope)\n")
        expect("missing own fragment", Site(root, "https://s.example", pages, {}, {}).check(), "names no heading in the page")

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pages = _fake_repo(root, extra_docs={"NEW.md": "# New\n"})
        expect("unlisted docs page", Site(root, "https://s.example", pages, {}, {}).check(), "not in scripts/docsite.py's PAGES")

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pages = _fake_repo(root, llms_links="- [x](docs/NOPE.md)\n")
        expect("llms.txt broken link", Site(root, "https://s.example", pages, {}, {}).check(), "llms.txt: link")

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        pages = _fake_repo(root)
        pages.append(Page("docs/GHOST.md", "/docs/ghost/", "Ghost", "d", "g"))
        expect("PAGES names a missing file", Site(root, "https://s.example", pages, {}, {}).check(), "does not exist")

    if failures:
        print("docsite --selftest: FAIL")
        for f in failures:
            print("  - " + f)
        return 1
    print("docsite --selftest: the checks fail when they should")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default="dist/site", help="output directory (replaced)")
    ap.add_argument("--base-url", default=os.environ.get("M0_SITE_URL", DEFAULT_BASE),
                    help="the URL the site is served at; canonical links, the sitemap "
                         "and llms.txt are absolute (default: $M0_SITE_URL or %(default)s)")
    ap.add_argument("--check", action="store_true", help="link integrity only; stdlib only")
    ap.add_argument("--selftest", action="store_true", help="prove the checks can fail")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    site = Site(REPO, args.base_url)
    if args.check:
        problems = site.check()
        if problems:
            print("docsite --check: FAIL")
            for p in problems:
                print("  - " + p)
            return 1
        print(f"docsite --check: {len(site.pages)} pages, every link resolves")
        return 0
    n = site.build(args.out)
    if args.base_url == DEFAULT_BASE:
        print(f"docsite: built {n} pages into {args.out} for {args.base_url} "
              "(pass --base-url or set M0_SITE_URL for a deployable build)")
    else:
        print(f"docsite: built {n} pages into {args.out} for {args.base_url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
