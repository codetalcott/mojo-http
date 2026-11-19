"""Helpers several test files had each carried a byte-identical copy of.

Not a test file (no `test_` prefix, no `main`): the suite runner builds and
runs only those, and a test imports this as `test.support`. A helper joins
only when every copy is the same; a file whose variant differs keeps its own.
"""

from std.ffi import c_int, external_call, get_errno
from std.memory.alloc import unsafe_alloc

from m0_server.c.fcntl import set_nonblocking
from m0_server.http import HTTPResponse
from m0_server.event_loop_backend import EventLoopBackend
from m0_server.http.common_response import InternalError
from m0_server.loop.request import _drain_pipelined
from m0_server.loop.response import _finish_response
from m0_server.loop.state import LoopState, UNUSED
from m0_server.service import HTTPService


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
    set_nonblocking(RawFileDescriptor(c_int(pair[0])))
    set_nonblocking(RawFileDescriptor(c_int(pair[1])))
    return pair


def _raw(*bytes: Int) -> String:
    """A String holding exactly these bytes, valid UTF-8 or not."""
    var l = List[UInt8]()
    for b in bytes:
        l.append(UInt8(b))
    return String(unsafe_from_utf8=Span(l))


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


def _run_parked[T: HTTPService, B: EventLoopBackend](
    mut handler: T, mut backend: B, mut st: LoopState, slots: List[Int],
) -> Int:
    """Answer parked requests as a pool thread's completion would, without
    the thread: take each request back, run the handler, and finish the
    response on the loop. The tests' stand-in for a job coming back. It
    was the loop's own fallback for a submit batch the channel refused,
    until such a batch was made to wait instead (SPEC L39). Returns how
    many the handler ran: a slot no longer offloaded is skipped, and one
    whose client left is released unanswered, neither of them counted."""
    if len(slots) == 0:
        return 0
    ref pool = st.offload.pool()[]
    var ran = 0
    for i in range(len(slots)):
        var slot = slots[i]
        if slot < 0 or slot >= len(st.slot_fds) or not st.offload.offloaded[slot]:
            continue
        st.offload.offloaded[slot] = False
        st.offload.inflight -= 1
        var request = pool.unpark_request(slot)
        if st.slot_fds[slot] == UNUSED:
            # The client left while its request sat in the buffer; nothing
            # to answer, and the provision is released as an abandoned
            # completion's would be.
            pool.discard(slot)
            st.provision_pool.release(slot)
            continue
        var request_method = request.method
        var request_path = request.uri.path
        var response: HTTPResponse
        try:
            response = handler.func(request)
        except:
            response = InternalError()
            st.provision_pool.provisions[slot].should_close = True
        ran += 1
        handler.after_response(request_method, request_path, response)
        _finish_response(handler, backend, st, slot, st.slot_fds[slot], response^)
        _drain_pipelined(handler, backend, st, slot, st.slot_fds[slot])
    return ran
