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
        and print the worst sample, the second-worst, and where the worst
        one spent its time; the caller says what they mean
    ramp_probe.py selftest
        the placement summary against sample lists whose answers are
        known; exits 1 on a wrong one, and starts nothing

Each prints one summary line and exits 0, or exits 1 naming the phase and
the first difference. Stdlib only.

Why the two halves. A dead link shows only when it is clicked
(`smoke-mojo-mount`'s rule), so a rendered link is followed rather than
read. And "identical outside the prefix" would be wrong -- m0serve
answers `/` from its Python mount and an unmounted path with its own JSON
404 before any lane is chosen, while the host has neither -- but asserting
nothing there would hide a prefix that swallowed `/xapp`, so each outside
path is asserted for what its host owns.

The placement line, and why it carries two statistics:

    worst_now_ms=120 second_now_ms=2 worst_connect_ms=0 worst_request_ms=119 slow_requests=20

`smoke-ramp` gates on `second_now_ms`, the second-worst of the 24. What
the gate exists to catch -- `/now` answered from a pool thread, or the
lane's other thread not answering -- puts a sample behind a 200 ms view
whenever it lands in the view's first half, so several of 24 wait 100 ms
or more and the second-worst is over the bound with the worst. A shared
macOS runner, though, stalls about one sample in a thousand for 80 to
120 ms, and the worst of 24 has no margin for one: `Tests` run
36898942895 failed at 120 ms in the host's full-lane arm, where the worst
sample of each of 40 green runs had been 8 ms or less. `worst_now_ms` is
still printed and still recorded, so a runner that stalls more often
shows in the numbers before it shows as a red run.

`worst_connect_ms` and `worst_request_ms` say where the worst sample
spent its time: the connect (on loopback the kernel completes it with no
part taken by the server's loop, so a slow one is the client's side or
the runner's) and the request, from its first byte written to the last
byte of the answer read (the server, or the probe not being scheduled).
The total also holds the close, which is in neither, so a stall both
figures leave unexplained was the probe itself not running.
"""

from __future__ import annotations

import http.client
import random
import re
import sys
import threading
import time

from probelib import fail, phase, stamp

stamp("ramp_probe: FAIL", fail="ramp_probe: FAIL: {phase}: {msg}", stream=sys.stderr)


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


def summarize(samples: list) -> dict:
    """The placement line's numbers, from `(total, connect, request)` per
    sample, each in milliseconds. A pure function of the list.

    `second_now_ms` is the second-largest total (equal to the worst when two
    samples tie for it), and the connect and request figures are the WORST
    sample's own, not each column's maximum: they say where that one
    sample's time went. Whole milliseconds, truncated, as `worst_now_ms`
    always was. Fewer than two samples have no second-worst, and are
    refused rather than answered with the only one.
    """
    if len(samples) < 2:
        raise ValueError(
            "%d sample(s): a second-worst needs at least two" % len(samples)
        )
    ordered = sorted(samples, key=lambda s: s[0], reverse=True)
    worst, second = ordered[0], ordered[1]
    return {
        "worst_now_ms": int(worst[0]),
        "second_now_ms": int(second[0]),
        "worst_connect_ms": int(worst[1]),
        "worst_request_ms": int(worst[2]),
    }


SUMMARY_FIELDS = ("worst_now_ms", "second_now_ms", "worst_connect_ms", "worst_request_ms")


def summary_line(samples: list, slow_requests: int) -> str:
    got = summarize(samples)
    fields = ["%s=%d" % (name, got[name]) for name in SUMMARY_FIELDS]
    return " ".join(fields + ["slow_requests=%d" % slow_requests])


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
    samples: list = []
    for _ in range(PLACEMENT_SAMPLES):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        t0 = time.perf_counter()
        try:
            conn.connect()
            t1 = time.perf_counter()
            conn.request("GET", prefix + "/now")
            resp = conn.getresponse()
            resp.read()
            t2 = time.perf_counter()
        finally:
            conn.close()
        if resp.status != 200:
            fail("%s/now answered HTTP %d under the load" % (prefix, resp.status))
        # The total ends where it always did, after the close.
        total = (time.perf_counter() - t0) * 1000.0
        samples.append((total, (t1 - t0) * 1000.0, (t2 - t1) * 1000.0))
        time.sleep(random.uniform(0.05, 0.3))
    for t in loaders:
        t.join(timeout=seconds + 30)
    if len(counts) != k or min(counts) == 0:
        fail("the slow connections did not all serve: %r" % counts)
    print(summary_line(samples, sum(counts)))


SELFTEST_BOUND_MS = 100
"""`smoke-ramp`'s bound, for the selftest's two verdicts. The gate itself is
the task's `[ "$x" -lt 100 ]`; this only says which side each case is on."""


def selftest() -> None:
    """`summarize` against lists whose answers are known. No sockets."""
    phase("the selftest")
    wrong = []
    checks = [0]

    def check(what: str, ok: bool) -> None:
        checks[0] += 1
        if not ok:
            print("  WRONG  %s" % what)
            wrong.append(what)

    quiet = (2.9, 0.4, 2.3)
    stall = (120.7, 0.5, 119.9)

    # One runner stall among 24: the worst sees it, the gate's statistic
    # does not.
    one = summarize([quiet] * 11 + [stall] + [quiet] * 12)
    check("one stall of 120 ms in 24: the worst is 120", one["worst_now_ms"] == 120)
    check("one stall of 120 ms in 24: the second-worst is 2", one["second_now_ms"] == 2)
    check("one stall of 120 ms in 24: the second-worst is under the bound",
          one["second_now_ms"] < SELFTEST_BOUND_MS)

    # Two of them is what a regression looks like, and is over it.
    two = summarize([stall] + [quiet] * 22 + [stall])
    check("two samples of 120 ms in 24: the second-worst is 120", two["second_now_ms"] == 120)
    check("two samples of 120 ms in 24: the second-worst is over the bound",
          two["second_now_ms"] >= SELFTEST_BOUND_MS)

    # The split is the worst SAMPLE's, not each column's maximum: here the
    # slowest connect and the slowest request belong to other samples.
    split = summarize([(50.0, 45.0, 4.0), (120.0, 1.0, 118.0), (60.0, 2.0, 57.0)])
    check("the connect and request times are the worst sample's own",
          (split["worst_connect_ms"], split["worst_request_ms"]) == (1, 118))
    check("the second-worst of three is the middle one", split["second_now_ms"] == 60)
    slow_connect = summarize([(3.0, 1.0, 2.0), (95.0, 90.0, 4.0)])
    check("a stall in the connect is reported as one",
          (slow_connect["worst_connect_ms"], slow_connect["worst_request_ms"]) == (90, 4))

    # Order does not matter, and the answer does not depend on which of two
    # equal samples sorts first.
    shuffled = [quiet] * 22 + [stall, (80.2, 0.3, 79.5)]
    random.shuffle(shuffled)
    check("the answer does not depend on the order of the samples",
          summarize(shuffled) == summarize(sorted(shuffled)))

    # Refused by name: an answer is wrong, and so is any other exception --
    # an IndexError is the function falling over, not saying no.
    for few in ([], [stall]):
        try:
            summarize(few)
            refused = False
        except ValueError:
            refused = True
        except Exception:
            refused = False
        check("%d sample(s) are refused, not summarised" % len(few), refused)

    line = summary_line([quiet] * 23 + [stall], 20)
    check("the line keeps worst_now_ms= first and slow_requests= last",
          line == "worst_now_ms=120 second_now_ms=2 worst_connect_ms=0 "
                  "worst_request_ms=119 slow_requests=20")

    if wrong:
        print("ramp_probe: FAIL: selftest: %d wrong answer(s)" % len(wrong))
        sys.exit(1)
    print("ramp_probe selftest OK (%d checks)" % checks[0])


def main() -> None:
    a = sys.argv
    if len(a) == 5 and a[1] == "bytes":
        bytes_phase(int(a[2]), int(a[3]), a[4])
    elif len(a) == 6 and a[1] == "placement":
        placement(int(a[2]), a[3], int(a[4]), float(a[5]))
    elif len(a) == 2 and a[1] == "selftest":
        selftest()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
