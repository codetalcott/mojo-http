"""End-to-end check for the HTTP client, driven by `poe smoke-client`.

Runs real requests against the notes API on :8091 — the first smoke in this
repo where both ends of the wire are Mojo. Asserts by raising: a failure
exits nonzero and the smoke task fails.

Lives at the package root, outside `src/` (it is a program, not a library
module) and outside `test/` (it needs a live server, which `test-http` must
not). `mojo run -I packages/m0-http -I packages/m0-core
packages/m0-http/client_check.mojo` — package first, so `src.*` resolves
here.
"""

from lightbug_http.io.bytes import Bytes

from src.client import Client


def _body_string(body: List[UInt8]) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(body)))


def main() raises:
    var client = Client(timeout_s=10)
    var base = String("http://localhost:8091")

    # The basic round trip: status, headers, body.
    var health = client.get(base + "/health")
    if health.status_code != 200:
        raise Error("health: expected 200, got ", health.status_code)
    if _body_string(health.body_raw).find('"status":"ok"') < 0:
        raise Error("health: unexpected body: ", _body_string(health.body_raw))

    # POST with a body: the request line, Content-Length, and body all cross.
    var created = client.post(
        base + "/notes",
        Bytes(String('{"title":"from the mojo client","body":"hi"}').as_bytes()),
    )
    if created.status_code != 201:
        raise Error("create: expected 201, got ", created.status_code)
    var location = created.headers.get("location")
    if not location:
        raise Error("create: no Location header")
    if _body_string(created.body_raw).find("from the mojo client") < 0:
        raise Error("create: body did not echo the note")

    # Content negotiation from the client side.
    var html = client.get(base + String(location.value()), accept="text/html")
    if _body_string(html.body_raw).find("<h1>from the mojo client</h1>") < 0:
        raise Error("negotiation: HTML representation did not come back")

    # An error status is a response, not an exception.
    var missing = client.get(base + "/notes/999")
    if missing.status_code != 404:
        raise Error("missing: expected 404, got ", missing.status_code)
    var ct = missing.headers.get("content-type")
    if not ct:
        raise Error("missing: no content-type")
    if ct.value() != "application/problem+json":
        raise Error("missing: expected problem+json, got ", ct.value())

    # HEAD is the framing trap: the response advertises its GET twin's
    # Content-Length but sends no body. If the client waited for those
    # bytes the connection would hang; if it misjudged the boundary, the
    # NEXT request on the same connection would parse garbage.
    var head = client.request("HEAD", base + "/health")
    if head.status_code != 200:
        raise Error("head: expected 200, got ", head.status_code)
    if len(head.body_raw) != 0:
        raise Error("head: body must be empty, got ", len(head.body_raw), " bytes")
    var after_head = client.get(base + "/health")
    if after_head.status_code != 200:
        raise Error("get-after-head: connection desynced (", after_head.status_code, ")")

    # Everything above rode ONE TCP connection — that is what keep-alive
    # means, and every response parsing cleanly is what proves the computed
    # framing boundaries were exact.
    if client.connections_opened != 1:
        raise Error(
            "keep-alive: expected 1 connection for the whole conversation,"
            " dialed ", client.connections_opened,
        )

    # keep_alive=False restores one-connection-per-request exactly.
    var cold = Client(timeout_s=10, keep_alive=False)
    _ = cold.get(base + "/health")
    _ = cold.get(base + "/health")
    if cold.connections_opened != 2:
        raise Error(
            "keep_alive=False: expected 2 dials for 2 requests, got ",
            cold.connections_opened,
        )

    # A refused connection is an error, and a legible one.
    var refused = False
    try:
        _ = client.get("http://localhost:1/")
    except:
        refused = True
    if not refused:
        raise Error("a connection to a closed port did not fail")

    # And https is rejected up front, not half-attempted.
    var rejected = False
    try:
        _ = client.get("https://localhost:8091/health")
    except:
        rejected = True
    if not rejected:
        raise Error("an https:// URL was not rejected")

    print("client-check OK")
