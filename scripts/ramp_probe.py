"""Compare the ramp module on its two hosts, for `poe smoke-ramp` (SPEC N20).

    ramp_probe.py bytes M0SERVE_PORT HOST_PORT PREFIX
        issue a fixed request set under PREFIX to both, require every
        response byte-identical apart from `Date`, follow the index's
        rendered links on each, and assert the paths OUTSIDE the prefix
        per host: m0serve's Python application at `/`, the host's table
        404, and `/xapp` answered by neither mount
    ramp_probe.py placement PORT PREFIX K SECONDS
        hold K connections each looping `GET PREFIX/slow?ms=200` for
        SECONDS while sampling `GET PREFIX/now` 24 times at random gaps,
        and print the worst sample; the caller says what it means

Each prints one summary line and exits 0, or exits 1 naming the phase and
the first difference. Stdlib only.

Why the two halves. A dead link shows only when it is clicked
(`smoke-mojo-mount`'s rule), so a rendered link is followed rather than
read. And "identical outside the prefix" would be wrong -- m0serve
answers `/` from its Python mount and an unmounted path with its own JSON
404 before any lane is chosen, while the host has neither -- but asserting
nothing there would hide a prefix that swallowed `/xapp`, so each outside
path is asserted for what its host owns.
"""

from __future__ import annotations

import http.client
import random
import re
import sys
import threading
import time
import traceback

PHASE = "startup"


def phase(name):
    global PHASE
    PHASE = name


def _stamped(kind, exc, tb):
    traceback.print_exception(kind, exc, tb)
    print("ramp_probe: FAIL: %s: %r" % (PHASE, exc), file=sys.stderr)


sys.excepthook = _stamped


def fail(msg: str) -> None:
    print("ramp_probe: FAIL: %s: %s" % (PHASE, msg), file=sys.stderr)
    sys.exit(1)


def fetch(port: int, method: str, path: str):
    """(status, reason, sorted header pairs minus Date, body)."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        conn.request(method, path)
        resp = conn.getresponse()
        body = resp.read()
        headers = sorted(
            (k.lower(), v) for k, v in resp.getheaders() if k.lower() != "date"
        )
        return resp.status, resp.reason, headers, body
    finally:
        conn.close()


REQUESTS = [
    ("GET", "/"),
    ("GET", "/now"),
    ("GET", "/search?sel=10&k=5"),
    ("GET", "/search"),
    ("GET", "/slow?ms=5"),
    ("GET", "/nope"),
    ("POST", "/now"),
    ("OPTIONS", "/now"),
    ("DELETE", "/search"),
]
"""Under the prefix: the index, the loop route, the compute route with and
without parameters, the load route, a 404 inside the prefix, a 405 with
`Allow`, an `OPTIONS` 204, and a 405 on a writing route."""

EXPECT_STATUS = {
    ("GET", "/"): 200, ("GET", "/now"): 200, ("GET", "/search?sel=10&k=5"): 200,
    ("GET", "/search"): 200, ("GET", "/slow?ms=5"): 200, ("GET", "/nope"): 404,
    ("POST", "/now"): 405, ("OPTIONS", "/now"): 204, ("DELETE", "/search"): 405,
}


def compare(m0: int, host: int, method: str, path: str, what: str) -> tuple:
    a = fetch(m0, method, path)
    b = fetch(host, method, path)
    if a != b:
        lines = ["%s %s differs (%s):" % (method, path, what)]
        if a[0] != b[0] or a[1] != b[1]:
            lines.append("  status: m0serve %s %s, host %s %s" % (a[0], a[1], b[0], b[1]))
        if a[2] != b[2]:
            lines.append("  headers: m0serve %r" % (a[2],))
            lines.append("           host    %r" % (b[2],))
        if a[3] != b[3]:
            lines.append("  body: m0serve %r" % (a[3][:200],))
            lines.append("        host    %r" % (b[3][:200],))
        fail("\n".join(lines))
    return a


def bytes_phase(m0: int, host: int, prefix: str) -> None:
    phase("the request set under the prefix")
    compared = 0
    for method, path in REQUESTS:
        status, reason, headers, body = compare(m0, host, method, prefix + path, "the request set")
        want = EXPECT_STATUS[(method, path)]
        if status != want:
            fail("%s %s%s answered %d on both, expected %d" % (method, prefix, path, status, want))
        if status == 405 or method == "OPTIONS":
            allow = dict(headers).get("allow")
            if not allow or "GET" not in allow or "OPTIONS" not in allow:
                fail("%s %s%s carries no usable Allow: %r" % (method, prefix, path, allow))
        compared += 1

    phase("following the index's rendered links")
    _, _, _, index = fetch(m0, "GET", prefix + "/")
    hrefs = re.findall(rb'href="([^"]*)"', index)
    if len(hrefs) < 2:
        fail("the index rendered %d link(s), expected 2: %r" % (len(hrefs), index[:200]))
    followed = 0
    for href in hrefs:
        url = href.decode().replace("&amp;", "&")
        if not url.startswith(prefix + "/"):
            fail("the rendered link %s does not carry the prefix %s" % (url, prefix))
        status, _, _, body = compare(m0, host, "GET", url, "a followed link")
        if status != 200:
            fail("following %s answered %d" % (url, status))
        if b'"route":"now"' not in body and b'"top":[' not in body:
            fail("following %s reached neither now nor search: %r" % (url, body[:120]))
        followed += 1
    # The same link without its prefix is the dead one on both hosts.
    bare = hrefs[0].decode()[len(prefix):]
    for port, name in ((m0, "m0serve"), (host, "the host")):
        status, _, _, body = fetch(port, "GET", bare)
        if status != 404:
            fail("%s answered %s without its prefix with %d, not 404" % (name, bare, status))
        if b'"route":"now"' in body:
            fail("%s answered %s from the mount without its prefix" % (name, bare))

    phase("the paths outside the prefix, per host")
    status, _, _, body = fetch(m0, "GET", "/")
    if status != 200 or b"bare wsgi app" not in body:
        fail("m0serve's Python mount at / did not answer: %d %r" % (status, body[:120]))
    status, _, headers, body = fetch(host, "GET", "/")
    if status != 404:
        fail("the host answered / with %d, not the table's 404" % status)
    if dict(headers).get("content-type") != "application/problem+json":
        fail("the host's 404 outside the prefix is not the table's problem+json: %r" % (headers,))
    for port, name in ((m0, "m0serve"), (host, "the host")):
        status, _, _, body = fetch(port, "GET", prefix + "app/now")
        if b'"route":"now"' in body:
            fail("%s: the prefix %s swallowed %sapp/now" % (name, prefix, prefix))
        if name == "the host" and status != 404:
            fail("the host answered %sapp/now with %d, not 404" % (prefix, status))
    print(
        "compared=%d followed=%d outside=asserted" % (compared, followed)
    )


PLACEMENT_SAMPLES = 24
SLOW_MS = 200


def _slow_loop(port: int, prefix: str, until: float, counts: list) -> None:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    n = 0
    while time.perf_counter() < until:
        conn.request("GET", "%s/slow?ms=%d" % (prefix, SLOW_MS))
        resp = conn.getresponse()
        resp.read()
        if resp.status != 200:
            fail("a /slow request answered HTTP %d" % resp.status)
        n += 1
    conn.close()
    counts.append(n)


def placement(port: int, prefix: str, k: int, seconds: float) -> None:
    phase("holding %d connections on %s/slow" % (k, prefix))
    until = time.perf_counter() + seconds
    counts: list = []
    loaders = [
        threading.Thread(target=_slow_loop, args=(port, prefix, until, counts), daemon=True)
        for _ in range(k)
    ]
    for t in loaders:
        t.start()
    time.sleep(0.3)
    phase("sampling %s/now under the load" % prefix)
    worst = 0.0
    for _ in range(PLACEMENT_SAMPLES):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        t0 = time.perf_counter()
        try:
            conn.request("GET", prefix + "/now")
            resp = conn.getresponse()
            resp.read()
        finally:
            conn.close()
        if resp.status != 200:
            fail("%s/now answered HTTP %d under the load" % (prefix, resp.status))
        worst = max(worst, (time.perf_counter() - t0) * 1000.0)
        time.sleep(random.uniform(0.05, 0.3))
    for t in loaders:
        t.join(timeout=seconds + 30)
    if len(counts) != k or min(counts) == 0:
        fail("the slow connections did not all serve: %r" % counts)
    print("worst_now_ms=%d slow_requests=%d" % (int(worst), sum(counts)))


def main() -> None:
    a = sys.argv
    if len(a) == 5 and a[1] == "bytes":
        bytes_phase(int(a[2]), int(a[3]), a[4])
    elif len(a) == 6 and a[1] == "placement":
        placement(int(a[2]), a[3], int(a[4]), float(a[5]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
