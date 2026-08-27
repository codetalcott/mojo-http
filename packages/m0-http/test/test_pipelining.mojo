"""The keep-alive reset must preserve a pipelined tail — and ONLY then.

RFC 9112 §9.3: a server must be able to receive pipelined requests. The
socket-level behaviour is pinned by `scripts/pipeline_probe.py`
(`poe smoke-pipelining`); what these tests pin is the provision-level
contract underneath it. Bytes past `request_end` survive exactly one
path — a keep-alive reset passing `keep_pipelined=True` — and every other
reset clears the buffer whole, because a tail preserved on accept or
close would be one client's bytes leaking into another connection's
first request.
"""

from std.testing import assert_equal, TestSuite

from lightbug_http.server import ConnectionProvision
from lightbug_http.server_config import ServerConfig


def _provision_with(buf: String, request_end: Int) raises -> ConnectionProvision:
    var p = ConnectionProvision(ServerConfig())
    p.recv_buffer.extend(buf.as_bytes())
    p.request_end = request_end
    return p^


def _assert_buffer(p: ConnectionProvision, expected: String) raises:
    assert_equal(len(p.recv_buffer), expected.byte_length())
    var want = expected.as_bytes()
    for i in range(len(want)):
        assert_equal(p.recv_buffer[i], want[i])


def test_keep_pipelined_preserves_tail() raises:
    var p = _provision_with("REQ1TAIL", 4)
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "TAIL")
    # The stamp is spent: the tail is a NEW request whose end is unknown.
    assert_equal(p.request_end, 0)
    # And the tail has never been scanned for a terminator.
    assert_equal(p.last_parse_len, 0)


def test_keep_pipelined_without_request_end_clears() raises:
    """0 means "end unknown" — nothing can be safely preserved."""
    var p = _provision_with("REQ1TAIL", 0)
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "")


def test_keep_pipelined_with_no_tail_clears() raises:
    var p = _provision_with("REQ1", 4)
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "")


def test_default_reset_clears_despite_tail() raises:
    """The accept/close contract: without the explicit opt-in the buffer
    clears whole, request_end notwithstanding — a preserved tail there
    would cross connections."""
    var p = _provision_with("REQ1TAIL", 4)
    p.prepare_for_new_request()
    _assert_buffer(p, "")
    assert_equal(p.request_end, 0)


def test_preserved_tail_then_default_reset_clears() raises:
    var p = _provision_with("REQ1TAIL", 4)
    p.prepare_for_new_request(keep_pipelined=True)
    _assert_buffer(p, "TAIL")
    p.prepare_for_new_request()
    _assert_buffer(p, "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
