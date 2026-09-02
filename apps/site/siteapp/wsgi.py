"""The fallback behind the documentation site's static mount.

The site is a static tree built by `scripts/docsite.py` and served by
`m0serve --static /=<dist>` -- every hit on a file the tree holds is answered
in the server, before Python, by `sendfile`. m0serve needs an application to
stand behind the mount, and this is it: it sees only what the mount did not
answer, and it does exactly two things there.

- A directory named without its trailing slash. The static mount answers
  `/docs/spec/` with the directory's `index.html` and falls through on
  `/docs/spec`, deliberately -- the module says a redirect would be a new
  promise about URL shape, and it is right that the mount should not make
  it. This site DOES make that promise, so the redirect lives here, in the
  one application that knows the tree: a permanent redirect to the slashed
  form, query string kept.
- Everything else is the site's own `404.html`, with the status to match.
  (A traversal never gets here: the mount refuses those itself.)

`M0_SITE_DIST` names the built tree (default `dist/site`, relative to the
working directory), which must be the same directory the `--static` flag
was given, or the redirect would promise pages the mount cannot serve.
"""

import os
from pathlib import Path

DIST = Path(os.environ.get("M0_SITE_DIST", "dist/site")).resolve()


def _index_exists(path):
    """Whether `<dist>/<path>/index.html` is a regular file inside the tree.

    Resolved and re-checked against DIST, so a `..` in the request cannot
    make this answer for a directory outside the built site.
    """
    candidate = (DIST / path.lstrip("/")).resolve()
    try:
        candidate.relative_to(DIST)
    except ValueError:
        return False
    return (candidate / "index.html").is_file()


def application(environ, start_response):
    path = environ.get("PATH_INFO", "/") or "/"
    if not path.endswith("/") and _index_exists(path):
        location = path + "/"
        if environ.get("QUERY_STRING"):
            location += "?" + environ["QUERY_STRING"]
        start_response(
            "301 Moved Permanently",
            [
                ("Location", location),
                ("Content-Type", "text/plain; charset=utf-8"),
                ("Content-Length", "0"),
            ],
        )
        return [b""]

    page = DIST / "404.html"
    if page.is_file():
        body = page.read_bytes()
    else:
        body = b"<!doctype html><title>Not found</title><h1>Not found</h1>\n"
    start_response(
        "404 Not Found",
        [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Length", str(len(body))),
        ],
    )
    return [body]
