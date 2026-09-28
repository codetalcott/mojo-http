"""A write to a peer that has gone costs its connection, not the process
(SPEC A25).

The kernel raises SIGPIPE on a write to a socket or pipe whose peer is
gone, and its default action ends the process. `ignore_sigpipe` is what
`run_event_loop` and the blocking `Server.serve` call before their first
send. `mojo run` ignores SIGPIPE itself, which is how a built server could
die of it while every test passed, so each test here puts the default back
first: if the ignore does nothing, the test process dies of the signal
(status 141), and `poe test-http`, which runs each file with `|| exit 1`,
fails. `smoke-host` holds the same on a built binary.
"""

from std.ffi import c_int, get_errno
from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http import HTTPRequest, HTTPResponse, HTTPService, OK
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.process import (
    SIG_DFL, SIG_IGN, SIGPIPE, _raw_signal, getpid, ignore_sigpipe, kill_process,
)
from lightbug_http.address import NetworkType
from lightbug_http.connection import NoTLSListener
from lightbug_http.server import Server


def _swap(disposition: Int) -> Int:
    """Install `disposition` for SIGPIPE; return the one it replaced."""
    return _raw_signal(c_int(SIGPIPE), disposition)


def test_a_write_to_a_closed_pipe_is_an_error_not_the_end() raises:
    """The kernel's own SIGPIPE, raised inside the write, as a send to a
    reset socket raises it. The shutdown pipe's `notify` documents a closed
    read end as ignored, which it is only once SIGPIPE is.

    covers: A25
    """
    var original = _swap(SIG_DFL)
    ignore_sigpipe()
    var p = create_shutdown_pipe()
    close_fd(p[0])
    p[1].notify()
    var err = get_errno()
    close_fd(p[1].fd)
    _ = _swap(original)
    # The write reached the closed pipe: surviving it proves nothing if it
    # never happened.
    assert_true(err == err.EPIPE, "the write to a closed pipe did not fail with EPIPE")


def test_kill_pipe_does_not_end_the_process() raises:
    """`kill -PIPE`, as `smoke-host` sends a built server.

    covers: A25
    """
    var original = _swap(SIG_DFL)
    ignore_sigpipe()
    assert_true(kill_process(getpid(), SIGPIPE))
    # A signal sent to the process may land on another thread a moment
    # after `kill` returns, so the disposition is read back as well.
    assert_equal(_swap(original), SIG_IGN)


struct _Unused(HTTPService):
    def __init__(out self):
        pass

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        return OK("unused", "text/plain")


def test_the_blocking_server_ignores_sigpipe_before_it_accepts() raises:
    """`Server.serve` does not pass through `run_event_loop`, so it makes
    the call itself. A socket never put in listen mode fails its first
    accept at once, which is `serve`'s only way out.

    covers: A25
    """
    var original = _swap(SIG_DFL)
    var ln: NoTLSListener[NetworkType.tcp4]
    try:
        ln = NoTLSListener[NetworkType.tcp4]()
    except:
        raise Error("socket() failed")
    var server = Server()
    var handler = _Unused()
    var raised = False
    try:
        server.serve(ln, handler)
    except:
        raised = True
    ln.close()
    _ = ln^
    var now = _swap(original)
    assert_true(raised, "serve returned without an accept failing")
    assert_equal(now, SIG_IGN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
