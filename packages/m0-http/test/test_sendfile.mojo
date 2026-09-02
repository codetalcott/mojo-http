"""Tests for the `sendfile(2)` binding.

These actually move bytes: a temp file on one side, a socketpair on the
other, and the received bytes compared to what was written. That matters
more here than in most bindings because the two platforms take their
arguments in different ORDERS (Darwin is file-then-socket, Linux is
socket-then-file) — a swap compiles cleanly on both and fails only at
runtime, so a test that never transfers anything would not catch it.

Not covered here: the partial-send path, where Darwin reports EAGAIN
*and* a positive count at the same time. Forcing it needs a socket whose
buffer is smaller than the transfer and a peer that never reads, which is
a timing-dependent setup at unit-test scale; the loop-level smoke that
serves a file larger than every buffer is where that path is exercised
for real.
"""

from std.ffi import c_int, c_size_t, c_uchar, external_call, get_errno
from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http.c.sendfile import SendFileResult, send_file
from lightbug_http.c.socket import close, recv
from lightbug_http.io.bytes import Bytes


comptime _AF_UNIX = 1
comptime _SOCK_STREAM = 1


def _socketpair_stream() raises -> Tuple[Int, Int]:
    """A SOCK_STREAM pair — `socketpair_dgram`'s twin, local to this test.

    Not reusing the shipped `socketpair_dgram`: Darwin's `sendfile` refuses
    anything that is not SOCK_STREAM, so a datagram pair would fail here
    for a reason that has nothing to do with the binding under test — which
    is exactly the false negative that sent this test down a blind alley
    once already.
    """
    # A two-element stack local rather than a heap allocation, for the
    # reason `c/sendfile.mojo` records: `alloc` without a `Layout` is
    # deprecated with no replacement on this toolchain, and the ratchet
    # counts every site.
    var fds = Array[c_int, 2](fill=c_int(0))
    var rc = external_call[
        "socketpair", c_int, c_int, c_int, c_int, type_of(Pointer(to=fds[0]))
    ](
        c_int(_AF_UNIX), c_int(_SOCK_STREAM), c_int(0), Pointer(to=fds[0])
    )
    if rc != 0:
        raise Error("socketpair() failed, errno: ", get_errno())
    return (Int(fds[0]), Int(fds[1]))


def _write_temp(path: String, contents: String) raises:
    with open(path, "w") as f:
        f.write(contents)


def _recv_into(fd: Int, mut buf: Bytes, n: Int) raises -> Int:
    return Int(
        recv(FileDescriptor(fd), Span(buf), c_size_t(n), c_int(0))
    )


def _close_fd(fd: Int):
    try:
        close(FileDescriptor(fd))
    except:
        pass


def test_zero_count_is_a_no_op() raises:
    """A zero-length body must not reach the syscall at all."""
    var r = send_file(-1, -1, 0, 0)
    assert_equal(r.sent, 0)
    assert_true(not r.again)
    assert_true(not r.failed())


def test_negative_count_is_a_no_op() raises:
    var r = send_file(-1, -1, 0, -5)
    assert_equal(r.sent, 0)
    assert_true(not r.failed())


def test_bad_descriptors_report_errno_not_success() raises:
    """A failed call must be distinguishable from a zero-byte success."""
    var r = send_file(-1, -1, 0, 16)
    assert_true(r.failed())
    assert_equal(r.sent, 0)


def test_sends_whole_small_file() raises:
    var path = String("/tmp/m0_sendfile_small.txt")
    var body = String("hello sendfile")
    _write_temp(path, body)

    var pair = _socketpair_stream()
    var recv_fd = pair[0]
    var send_fd = pair[1]

    var fd = open(path, "r")
    var in_fd = Int(fd._get_raw_fd())
    var r = send_file(send_fd, in_fd, 0, body.byte_length())
    fd.close()

    assert_true(not r.failed())
    assert_equal(r.sent, body.byte_length())

    # Read it back off the socket and compare byte for byte.
    var got = Bytes(capacity=body.byte_length())
    for _ in range(body.byte_length()):
        got.append(0)
    var n = _recv_into(recv_fd, got, body.byte_length())
    assert_equal(n, body.byte_length())
    var text = String(StringSlice(unsafe_from_utf8=Span(got)))
    assert_equal(text, body)

    _close_fd(recv_fd)
    _close_fd(send_fd)


def test_offset_skips_the_prefix() raises:
    """The offset is per call, so a Range response can start mid-file."""
    var path = String("/tmp/m0_sendfile_offset.txt")
    var body = String("0123456789")
    _write_temp(path, body)

    var pair = _socketpair_stream()
    var recv_fd = pair[0]
    var send_fd = pair[1]

    var fd = open(path, "r")
    var in_fd = Int(fd._get_raw_fd())
    var r = send_file(send_fd, in_fd, 4, 3)  # "456"
    fd.close()

    assert_true(not r.failed())
    assert_equal(r.sent, 3)

    var got = Bytes(capacity=3)
    for _ in range(3):
        got.append(0)
    var n = _recv_into(recv_fd, got, 3)
    assert_equal(n, 3)
    assert_equal(String(StringSlice(unsafe_from_utf8=Span(got))), "456")

    _close_fd(recv_fd)
    _close_fd(send_fd)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
