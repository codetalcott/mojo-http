#!/usr/bin/env python3
"""FastHTML under m0serve beside uvicorn: one application, one scripted
scenario, both servers, and the responses compared (SPEC L36).

    uv run poe fasthtml-canary                 # what the weekly job runs
    python3 scripts/fasthtml_compare/compare.py run [--only NAME ...]
    python3 scripts/fasthtml_compare/compare.py --render       # docs/FASTHTML.md's table
    python3 scripts/fasthtml_compare/compare.py --check-page   # in the docs gate
    python3 scripts/fasthtml_compare/compare.py --selftest

`run` builds a virtualenv of the NEWEST python-fasthtml and uvicorn (nothing
here reads uv.lock: a release that breaks is the finding), clones FastHTML's
two example repositories, and serves every scenario from `bin/m0serve` and
from uvicorn. Each server gets its own copy of the application directory, so
no SQLite file or session key is shared.

What fails the run (`judge`, a pure function the selftest drives):

- a difference `EXPECTED` does not list;
- a listed difference that did not appear, or appeared with other values;
- one of this directory's own applications (`OWN = True`) not served by both;
- an upstream application that starts under one server and not the other;
- fewer than `SWEEP_FLOOR` example applications served by both.

An upstream application that starts under NEITHER is skipped and reported:
FastHTML's examples trail its releases, and that is not this server's.

`EXPECTED` is the one owner of "where m0serve answers differently from
uvicorn". docs/FASTHTML.md's table is rendered from it, and the docs gate
fails a page that no longer matches. To add or retire a difference, edit
`EXPECTED`, run `--render`, and commit both.

Timings are compared as booleans against wide bounds, never as numbers, so a
slow runner changes no answer.
"""
import argparse
import importlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PAGE = os.path.join(REPO, "docs", "FASTHTML.md")
BEGIN = "<!-- generated: fasthtml-differences -- edit EXPECTED in scripts/fasthtml_compare/compare.py, not this table -->"
END = "<!-- /generated: fasthtml-differences -->"

# Each entry: where the difference shows (scenario, step), a string each
# server's side of the differing step must contain, and the page's row.
# `row` is the SPEC id that owns the behaviour, or "" where this comparison
# is the only gate.
EXPECTED = [
    {
        "id": "state-m0",
        "scenario": "surface", "step": "GET /state-keys",
        "m0": '[\\"m0\\"]', "uv": "[]",
        "what": "`scope[\"state\"]`",
        "m0serve": "carries `m0`, the cross-worker publisher, beside what the application's lifespan put there",
        "uvicorn": "only what the lifespan put there",
        "row": "L12",
    },
    {
        "id": "chunked-scope",
        "scenario": "surface", "step": "POST /scope chunked",
        "m0": '[\\"content-length\\",\\"7\\"]', "uv": '[\\"transfer-encoding\\",\\"chunked\\"]',
        "what": "the scope's headers for a request sent with `Transfer-Encoding: chunked`",
        "m0serve": "`content-length`, the size of the body the server already de-chunked",
        "uvicorn": "`transfer-encoding: chunked`",
        "row": "L25",
    },
    {
        "id": "chunked-upload",
        "scenario": "surface", "step": "POST /upload chunked",
        "m0": "got 200000 bytes", "uv": "Missing required field",
        "what": "a multipart upload sent chunked, to a handler taking an `UploadFile`",
        "m0serve": "the handler receives the file",
        "uvicorn": "FastHTML answers `400`: it reads a missing `Content-Length` as an empty form",
        "row": "L25",
    },
    {
        "id": "encoded-slash",
        "scenario": "surface", "step": "GET /p/slash",
        "m0": "name=a%2Fb", "uv": "404 Not Found",
        "what": "`%2F` in a path, on a route with a `{name}` parameter",
        "m0serve": "stays encoded in `scope[\"path\"]`: the route matches and the parameter is `a%2Fb`",
        "uvicorn": "decoded to `/`, so the route does not match: `404`",
        "row": "",
    },
]

INSTALL = ["python-fasthtml", "uvicorn", "fastlite", "sqlite-utils",
           "python-multipart", "httpx", "websockets"]
UPSTREAM = {
    "fasthtml": "https://github.com/AnswerDotAI/fasthtml.git",
    "fasthtml-example": "https://github.com/AnswerDotAI/fasthtml-example.git",
}
# Not served: it gives every WebSocket client a shell.
SWEEP_SKIP = {"xtermjs"}
# Fewer example applications than this served by both servers fails the run:
# a sweep that has thinned to nothing compares nothing.
SWEEP_FLOOR = 8

WORK = os.environ.get("FASTHTML_COMPARE_WORK", "")


def upstream(*parts):
    return os.path.join(WORK, *parts)


# ---------------------------------------------------------------- judging

def judge(outcomes, expected=EXPECTED, sweep_floor=0):
    """Pure: [{name, own, state, diffs}] -> (failures, notes).

    `state` is "ran", "neither" (started under neither server), "m0-only" or
    "uv-only". `diffs` is [(step, m0_text, uv_text)], the differing steps
    with each side's whole observation as text.
    """
    failures, notes = [], []
    by_key = {(e["scenario"], e["step"]): e for e in expected}
    seen = set()
    ran = set()
    for o in outcomes:
        name = o["name"]
        if o["state"] == "neither":
            if o["own"]:
                failures.append(f"{name}: started under neither server, and it is this repository's own application")
            else:
                notes.append(f"{name}: skipped, it starts under neither server")
            continue
        if o["state"] != "ran":
            other = "uvicorn" if o["state"] == "m0-only" else "m0serve"
            failures.append(f"{name}: did not start under {other}, and did under the other server")
            continue
        ran.add(name)
        for step, m0_text, uv_text in o["diffs"]:
            e = by_key.get((name, step))
            if e is None:
                failures.append(f"{name}: `{step}` differs, and EXPECTED does not list it")
            elif e["m0"] not in m0_text or e["uv"] not in uv_text:
                failures.append(f"{name}: `{step}` differs, but not as `{e['id']}` records it")
                seen.add(e["id"])
            else:
                seen.add(e["id"])
    swept = sum(n.startswith("sweep:") for n in ran)
    if swept < sweep_floor:
        failures.append(f"only {swept} example applications were served by both servers, "
                        f"under the floor of {sweep_floor}")
    for e in expected:
        if e["scenario"] in ran and e["id"] not in seen:
            failures.append(f"`{e['id']}` is listed as a difference and did not appear: "
                            f"retire it from EXPECTED and the page, with the SPEC row it cites")
    return failures, notes


# ---------------------------------------------------------------- the page

def render_table(expected=EXPECTED):
    rows = ["| | under m0serve | under uvicorn | row |", "|---|---|---|---|"]
    for e in expected:
        row = f"[{e['row']}](SPEC.md)" if e["row"] else "this comparison"
        rows.append(f"| {e['what']} | {e['m0serve']} | {e['uvicorn']} | {row} |")
    return "\n".join([BEGIN, *rows, END])


_REGION = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)


def page_problem(text, expected=EXPECTED):
    """Pure: the page's text -> a failure message, or None."""
    m = _REGION.search(text)
    if not m:
        return "docs/FASTHTML.md has no fasthtml-differences block"
    if m.group(0) != render_table(expected):
        return ("docs/FASTHTML.md's differences table is not what EXPECTED renders: "
                "run `python3 scripts/fasthtml_compare/compare.py --render`")
    return None


def render_page():
    with open(PAGE) as f:
        text = f.read()
    if not _REGION.search(text):
        sys.exit("docs/FASTHTML.md has no fasthtml-differences block to fill")
    with open(PAGE, "w") as f:
        f.write(_REGION.sub(lambda _: render_table(), text))


# ---------------------------------------------------------------- selftest

def selftest():
    ok = {"name": "surface", "own": True, "state": "ran", "diffs": [
        (e["step"], "x " + e["m0"], "y " + e["uv"]) for e in EXPECTED if e["scenario"] == "surface"]}
    cases = [
        ("every listed difference, nothing else", [ok], 0),
        ("an unlisted difference", [dict(ok, diffs=ok["diffs"] + [("GET /", "a", "b")])], 1),
        ("a listed difference with other values", [dict(ok, diffs=[(ok["diffs"][0][0], "a", "b")] + ok["diffs"][1:])], 1),
        ("a listed difference gone", [dict(ok, diffs=ok["diffs"][1:])], 1),
        ("an own application that did not start", [dict(ok, state="neither", diffs=[])], 1),
        ("an upstream application starting under neither", [ok, {"name": "sweep:x", "own": False, "state": "neither", "diffs": []}], 0),
        ("an upstream application starting under uvicorn alone", [ok, {"name": "sweep:x", "own": False, "state": "uv-only", "diffs": []}], 1),
        ("an upstream difference", [ok, {"name": "sweep:x", "own": False, "state": "ran", "diffs": [("GET /", "a", "b")]}], 1),
    ]
    bad = 0
    if len(judge([ok], sweep_floor=1)[0]) != 1:
        bad += 1
        print("selftest FAIL: a sweep under its floor passed")
    for label, outcomes, want in cases:
        got = len(judge(outcomes)[0])
        if got != want:
            bad += 1
            print(f"selftest FAIL: {label}: {got} failures, want {want}")
    page = "intro\n\n" + render_table() + "\n"
    for label, text, want in [
        ("the rendered page", page, False),
        ("a hand-edited table", page.replace("under uvicorn", "under Uvicorn"), True),
        ("no block", "intro\n", True),
    ]:
        if (page_problem(text) is not None) != want:
            bad += 1
            print(f"selftest FAIL: page: {label}")
    if bad:
        sys.exit(1)
    print(f"fasthtml_compare selftest: {len(cases) + 4} cases pass")


# ---------------------------------------------------------------- serving

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class NeverStarted(Exception):
    pass


class Server:
    def __init__(self, kind, m0serve, src_dir, spec, extra=(), env=None, setup=None):
        self.kind, self.m0serve, self.spec, self.extra = kind, m0serve, spec, list(extra)
        name = os.path.basename(src_dir.rstrip("/"))
        self.dir = os.path.join(WORK, "run", kind, name)
        shutil.rmtree(self.dir, ignore_errors=True)
        shutil.copytree(src_dir, self.dir)
        if setup:
            setup(self.dir)
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.logpath = os.path.join(WORK, "run", f"{kind}-{name}.log")
        # m0serve embeds the python3 first on PATH: the virtualenv's.
        self.env = dict(os.environ, PATH=os.path.join(WORK, "venv", "bin") + os.pathsep + os.environ["PATH"],
                        PYTHONUNBUFFERED="1")
        self.env.update(env or {})

    def start(self):
        if self.kind == "m0":
            cmd = [self.m0serve, self.spec]
        else:
            cmd = [os.path.join(WORK, "venv", "bin", "uvicorn"), self.spec]
        cmd += ["--host", "127.0.0.1", "--port", str(self.port), *self.extra]
        self.log = open(self.logpath, "w")
        self.proc = subprocess.Popen(cmd, cwd=self.dir, env=self.env, stdout=self.log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.time() + 30
        while time.time() < deadline:
            if self.proc.poll() is not None:
                self.log.close()
                raise NeverStarted(self.last_line())
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.5).close()
                time.sleep(0.3)
                return self
            except OSError:
                time.sleep(0.2)
        self.stop()
        raise NeverStarted("never listened")

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(8)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait()
        self.log.close()

    def read_log(self):
        with open(self.logpath, errors="replace") as f:
            return f.read()

    def last_line(self):
        lines = [l for l in self.read_log().splitlines() if l.strip()]
        return lines[-1][:200] if lines else "(no output)"


DROP = {"date", "server", "x-thread", "content-length", "transfer-encoding", "connection",
        "keep-alive", "etag", "last-modified"}


def norm_headers(h):
    out = {}
    for k, v in h.multi_items():
        k = k.lower()
        if k in DROP:
            continue
        v = re.sub(r"127\.0\.0\.1:\d+", "127.0.0.1:PORT", v)
        if k == "set-cookie":
            name = v.split("=", 1)[0]
            attrs = sorted(a.strip().split("=")[0].lower() for a in v.split(";")[1:])
            v = f"{name}=<..>; " + "; ".join(attrs)
        if k == "allow":  # Starlette joins a set
            v = ", ".join(sorted(m.strip() for m in v.split(",")))
        out.setdefault(k, []).append(v)
    return out


def obs(r, body_norm=None):
    """What a response is compared on: status, headers, body, and whether it
    was chunked. The body's length is the normalised text's."""
    body = r.content
    try:
        text = body.decode()
    except UnicodeDecodeError:
        text = f"<{len(body)} binary bytes>"
    text = re.sub(r"127\.0\.0\.1:\d+", "127.0.0.1:PORT", text)
    if body_norm:
        text = body_norm(text)
    return {"status": r.status_code, "headers": norm_headers(r.headers), "body": text,
            "te": r.headers.get("transfer-encoding")}


RETRIES = []


def _retry_dropped_connections():
    """uvicorn may close a keep-alive connection after an application error;
    the client's next request on it is then reset. That is not a response to
    compare, so the request is made once more, and counted."""
    import httpx
    orig = httpx.Client.request

    def request(self, *a, **k):
        try:
            return orig(self, *a, **k)
        except (httpx.ReadError, httpx.RemoteProtocolError) as e:
            RETRIES.append(repr(e))
            return orig(self, *a, **k)
    httpx.Client.request = request


def serve_both(name, sc, m0serve, m0_flags=()):
    """One scenario under each server -> an outcome for `judge`, plus lines."""
    results, started, lines = {}, {}, []
    for kind in ("m0", "uv"):
        extra = list(sc.EXTRA.get(kind, ())) + (list(m0_flags) if kind == "m0" else [])
        srv = Server(kind, m0serve, sc.APP_DIR, sc.SPEC, extra=extra,
                     env=getattr(sc, "ENV", None), setup=getattr(sc, "SETUP", None))
        try:
            srv.start()
        except NeverStarted as e:
            started[kind] = False
            lines.append(f"  [{kind}] did not start: {e}")
            continue
        started[kind] = True
        steps = []
        RETRIES.clear()
        try:
            try:
                sc.scenario(srv, steps)
            except Exception as e:  # the other server's steps still compare
                steps.append(("the scenario raised", {"exc": repr(e)[:300]}))
        finally:
            srv.stop()
        if hasattr(sc, "after_stop"):
            sc.after_stop(srv, steps)
        if RETRIES:
            lines.append(f"  [{kind}] {len(RETRIES)} request(s) repeated after a dropped keep-alive connection")
        results[kind] = steps
    if not any(started.values()):
        state = "neither"
    elif not all(started.values()):
        state = "m0-only" if started["m0"] else "uv-only"
    else:
        state = "ran"
    diffs = []
    if state == "ran":
        a, b = results["m0"], results["uv"]
        for i in range(max(len(a), len(b))):
            la, oa = a[i] if i < len(a) else ("(no step)", None)
            lb, ob = b[i] if i < len(b) else ("(no step)", None)
            if la != lb or oa != ob:
                diffs.append((la if la == lb else f"{la} / {lb}", json.dumps(oa), json.dumps(ob)))
                lines.append(f"  DIFF {diffs[-1][0]}\n    m0: {diffs[-1][1][:400]}\n    uv: {diffs[-1][2][:400]}")
        lines.insert(0, f"  {len(a) - len(diffs)} of {len(a)} steps the same")
    return {"name": name, "own": getattr(sc, "OWN", False), "state": state, "diffs": diffs}, lines


class Sweep:
    """Any example directory: its index, its favicon, a 404, and its index as
    htmx asks for it."""
    OWN = False
    EXTRA = {}

    def __init__(self, app_dir, module):
        self.APP_DIR, self.SPEC = app_dir, f"{module}:app"

    @staticmethod
    def SETUP(d):
        os.makedirs(os.path.join(d, "data"), exist_ok=True)

    @staticmethod
    def _norm(t):
        t = re.sub(r"hsl\(\d+", "hsl(N", t)
        return re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "UUID", t)

    def scenario(self, srv, steps):
        import httpx
        c = httpx.Client(base_url=srv.base, timeout=10)
        for p in ("/", "/favicon.ico", "/nope"):
            steps.append((f"GET {p}", obs(c.get(p), body_norm=self._norm)))
        steps.append(("GET / htmx", obs(c.get("/", headers={"HX-Request": "true"}), body_norm=self._norm)))


def sweep_targets():
    out = []
    root = upstream("fasthtml-example")
    for n in sorted(os.listdir(root)):
        d = os.path.join(root, n)
        if n in SWEEP_SKIP or not os.path.isdir(d):
            continue
        for module in ("main", "app"):
            if os.path.exists(os.path.join(d, module + ".py")):
                out.append((f"sweep:{n}", Sweep(d, module)))
                break
    return out


# ---------------------------------------------------------------- running

def sh(*cmd):
    subprocess.run(cmd, check=True)


def provision(work):
    """The virtualenv and the clones, once per work directory."""
    venv_py = os.path.join(work, "venv", "bin", "python")
    if not os.path.exists(venv_py):
        # The interpreter m0serve will embed: the minor this one runs.
        sh("uv", "venv", "--quiet", "--python", "%d.%d" % sys.version_info[:2], os.path.join(work, "venv"))
        sh("uv", "pip", "install", "--quiet", "--python", venv_py, *INSTALL)
    for name, url in UPSTREAM.items():
        if not os.path.isdir(os.path.join(work, name)):
            sh("git", "clone", "--quiet", "--depth", "1", url, os.path.join(work, name))
    return venv_py


def versions():
    from importlib.metadata import version
    out = [f"{p} {version(p)}" for p in ("python-fasthtml", "starlette", "uvicorn")]
    out.append("CPython " + sys.version.split()[0])
    for name in UPSTREAM:
        rev = subprocess.run(["git", "-C", upstream(name), "log", "-1", "--format=%h %cs"],
                             capture_output=True, text=True).stdout.strip()
        out.append(f"{name} at {rev}")
    return out


def run(args):
    if not WORK:
        # First entry: provision, then run again under the virtualenv, which
        # has the client libraries and the FastHTML the report names.
        work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="fasthtml-compare-")
        os.makedirs(work, exist_ok=True)
        venv_py = provision(work)
        env = dict(os.environ, FASTHTML_COMPARE_WORK=work)
        rc = subprocess.run([venv_py, os.path.abspath(__file__), *sys.argv[1:]], env=env).returncode
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)
        sys.exit(rc)

    m0serve = os.path.abspath(args.m0serve)
    if not os.path.exists(m0serve):
        sys.exit(f"{m0serve} is not built: uv run poe build-serve")
    _retry_dropped_connections()
    sys.path.insert(0, os.path.join(HERE, "scenarios"))
    sys.path.insert(0, HERE)
    sys.modules.setdefault("compare", sys.modules[__name__])
    names = sorted(f[:-3] for f in os.listdir(os.path.join(HERE, "scenarios")) if f.endswith(".py"))
    targets = [(n, importlib.import_module(n)) for n in names] + sweep_targets()
    if args.only:
        targets = [(n, sc) for n, sc in targets if n in args.only or n.split(":")[-1] in args.only]
        if not targets:
            sys.exit(f"no scenario named {args.only}")

    report = ["# FastHTML under m0serve beside uvicorn", "", ", ".join(versions()), ""]
    print(report[2], flush=True)
    outcomes = []
    for name, sc in targets:
        outcome, lines = serve_both(name, sc, m0serve, args.m0_flags.split())
        outcomes.append(outcome)
        block = [f"{name}: {outcome['state']}", *lines]
        print("\n".join(block), flush=True)
        report += block
    if args.only:
        # A partial run cannot say a listed difference is gone.
        ran = {o["name"] for o in outcomes}
        expected, floor = [e for e in EXPECTED if e["scenario"] in ran], 0
    else:
        expected, floor = EXPECTED, SWEEP_FLOOR
    failures, notes = judge(outcomes, expected, floor)
    ran = sum(o["state"] == "ran" for o in outcomes)
    tail = ["", *notes, "", f"{ran} of {len(outcomes)} applications served by both servers."]
    tail += [f"FAIL: {f}" for f in failures] or ["PASS: every difference is one docs/FASTHTML.md lists."]
    print("\n".join(tail), flush=True)
    if args.report:
        with open(args.report, "w") as f:
            f.write("\n".join(report + tail) + "\n")
    sys.exit(1 if failures else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", nargs="?", choices=["run"])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--render", action="store_true", help="rewrite docs/FASTHTML.md's table from EXPECTED")
    ap.add_argument("--check-page", action="store_true", help="fail if that table is stale")
    ap.add_argument("--work", help="keep the virtualenv, the clones and the logs here (default: a temporary directory, removed)")
    ap.add_argument("--m0serve", default=os.path.join(REPO, "bin", "m0serve"))
    ap.add_argument("--m0-flags", default="", help="extra m0serve flags, for a sabotage run")
    ap.add_argument("--only", nargs="+", help="scenario names; a sweep target by its directory")
    ap.add_argument("--report", help="also write the report here")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.render:
        return render_page()
    if args.check_page:
        with open(PAGE) as f:
            problem = page_problem(f.read())
        if problem:
            sys.exit(problem)
        print("docs/FASTHTML.md's differences table matches EXPECTED")
        return
    if args.command == "run":
        return run(args)
    ap.error("nothing to do: run, --selftest, --render or --check-page")


if __name__ == "__main__":
    main()
