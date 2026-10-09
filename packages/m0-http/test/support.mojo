"""Helpers several test files had each carried a byte-identical copy of.

Not a test file (no `test_` prefix, no `main`): the suite runner builds and
runs only those, and a test imports this as `test.support`. A helper joins
only when every copy is the same; a file whose variant differs keeps its own.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc

from lightbug_http.c.fcntl import set_nonblocking
from lightbug_http.http import HTTPResponse


def _stream_pair() raises -> Tuple[Int, Int]:
    """An `AF_UNIX` `SOCK_STREAM` pair, non-blocking at both ends: the first
    end is the server's side of a connection, the second the client's."""
    var fds = unsafe_alloc[c_int](count=2)
    var rc = external_call[
        "socketpair", c_int, c_int, c_int, c_int, type_of(fds)
    ](c_int(1), c_int(1), c_int(0), fds)  # AF_UNIX, SOCK_STREAM
    if rc != 0:
        var errno = get_errno()
        fds.unsafe_free()
        raise Error("socketpair() failed, errno: ", errno)
    var pair = (Int(fds[unsafe_offset=0]), Int(fds[unsafe_offset=1]))
    fds.unsafe_free()
    set_nonblocking(FileDescriptor(pair[0]))
    set_nonblocking(FileDescriptor(pair[1]))
    return pair


def _raw(*bytes: Int) -> String:
    """A String holding exactly these bytes, valid UTF-8 or not."""
    var l = List[UInt8]()
    for b in bytes:
        l.append(UInt8(b))
    return String(unsafe_from_utf8=Span(l))


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))
