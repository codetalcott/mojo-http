"""A write to a peer that has gone costs its connection, not the process
(SPEC A25).

The kernel raises SIGPIPE on a write to a socket or pipe whose peer is
gone, and its default action ends the process. `ignore_sigpipe` is what
`run_event_loop` calls before its first send, and every `Server` entry
point runs that loop. `mojo run` ignores SIGPIPE itself, which is how a
built server could die of it while every test passed, so each test here
puts the default back first: a missing ignore then kills the test process
(status 141) where a test provokes the signal, or leaves the default for
the test to read back where it does not, and `poe test-http`, which runs
each file with `|| exit 1`, fails either way. `smoke-host` holds the same
on a built binary.
"""

from std.ffi import c_int, c_uint, external_call, get_errno
from std.testing import assert_equal, assert_true, TestSuite

from lightbug_http import HTTPRequest, HTTPResponse, HTTPService, OK
from lightbug_http.c.pipe import close_fd, create_shutdown_pipe
from lightbug_http.c.process import (
    SIG_DFL, SIG_IGN, SIGPIPE, _raw_signal, getpid, ignore_sigpipe, kill_process,
)
from lightbug_http.connection import ListenConfig
from lightbug_http.server import Server


comptime WATCHDOG_S = 30
"""How long a `Server` entry point may run before SIGALRM ends this file. A
bound on a hang, never a measurement: with its shutdown pipe closed before
it starts, the event loop returns in milliseconds, while the blocking accept
loop `serve` and `listen_and_serve` used to run never read that pipe and
would wait in `accept` for a client that never comes."""


def _swap(disposition: Int) -> Int:
    """Install `disposition` for SIGPIPE; return the one it replaced."""
    return _raw_signal(c_int(SIGPIPE), disposition)


def _arm_watchdog(what: StringSpan):
    """Arm SIGALRM `WATCHDOG_S` from now, saying so first.

    Its default action ends the process with status 142, which `poe
    test-http` reads as a failure, where a hang would hold CI's unit-tests
    job to its cap. The line goes out flushed, before the call that may
    hang: the suite prints its report only at the end, and a process the
    alarm ends prints nothing more, so this line is what names the culprit.
    """
    print(
        "watchdog:", what, "must return within", WATCHDOG_S,
        "s, or SIGALRM ends this file (status 142)", flush=True,
    )
    _ = external_call["alarm", c_uint](c_uint(WATCHDOG_S))


def _disarm_watchdog():
    """Cancel the alarm `_arm_watchdog` set."""
    _ = external_call["alarm", c_uint](c_uint(0))


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


def test_serve_runs_the_event_loop_which_ignores_sigpipe() raises:
    """`Server.serve` is the event loop: it returns because the loop reads
    the server's shutdown pipe, closed here before it starts, and the
    disposition it leaves is the loop's ignore. The default goes back AFTER
    the listener is made, so nothing but `serve` can have set it.

    covers: A25
    """
    var ln = ListenConfig(max_bind_retries=1, quiet=True).listen("127.0.0.1:0")
    var stop = create_shutdown_pipe()
    stop[1].signal()
    var server = Server(shutdown_read_fd=stop[0])
    var handler = _Unused()
    var original = _swap(SIG_DFL)
    var err = String()
    _arm_watchdog("Server.serve, its shutdown pipe closed,")
    try:
        # The loop's now: it closes the listener as its drain begins.
        server.serve(ln^, handler)
    except e:
        err = String(e)
    _disarm_watchdog()
    var now = _swap(original)
    close_fd(stop[0])
    assert_equal(err, "")
    assert_equal(now, SIG_IGN)


def test_listen_and_serve_runs_the_event_loop_which_ignores_sigpipe() raises:
    """`listen_and_serve`, the entry point README shows, is the same loop:
    the server's shutdown pipe ends it, and SIGPIPE is ignored by then.

    covers: A25
    """
    var stop = create_shutdown_pipe()
    stop[1].signal()
    var server = Server(shutdown_read_fd=stop[0])
    var handler = _Unused()
    var original = _swap(SIG_DFL)
    var err = String()
    _arm_watchdog("Server.listen_and_serve, its shutdown pipe closed,")
    try:
        server.listen_and_serve("127.0.0.1:0", handler)
    except e:
        err = String(e)
    _disarm_watchdog()
    var now = _swap(original)
    close_fd(stop[0])
    assert_equal(err, "")
    assert_equal(now, SIG_IGN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
