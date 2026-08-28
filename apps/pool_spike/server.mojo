"""The Phase 2 measurement: does a handler pool help a BLOCKING Mojo handler?

Two routes and one variable. `/fast` answers immediately; `/slow?ms=N` blocks
the thread serving it in `usleep` for N milliseconds — standing in for the
database round trip, subprocess or outbound call an event loop cannot
multiplex away. `M0_POOL_THREADS` decides whether `func` runs on the loop
(0, the default) or on a pool thread (N > 0).

The question is whether the p99 of `/fast` collapses when slow requests are in
flight, and whether the pool restores it. `docs/BENCHMARKS.md` records the
Python answer for the same shape: p99 1.0 ms with no slow traffic, 190.7 ms
with slow traffic and no pool, 7.4 ms with slow traffic and a pool of four.
If a blocking Mojo handler does not show that collapse-and-recovery, the pool
buys nothing here and `m0_http.mojo_pool` should be deleted rather than kept.

The sleep is deliberately `usleep` and not a spin. A spin would measure the
wrong thing entirely: CPU work parallelises with `std.runtime.asyncrt`'s
`TaskGroup` at no plumbing cost (measured 3.6x on four tasks), so a pool is
not the answer to it. A pool exists for threads parked in a syscall.

    M0_PORT=8080 M0_POOL_THREADS=0 ./pool_spike     # loop serves func
    M0_PORT=8080 M0_POOL_THREADS=4 ./pool_spike     # pool serves func
"""

from std.ffi import c_int, external_call
from std.os import getenv

from lightbug_http import (
    JOIN_TIMEOUT_NS,
    MojoPool,
    PoolContext,
    PoolHandler,
    Server,
    HTTPRequest,
    HTTPResponse,
)
from lightbug_http.offload import OffloadPool
from m0_http import AppConfig, install_shutdown_signals, reply


def _query_int(req: HTTPRequest, key: String, fallback: Int) -> Int:
    """Read a decimal query parameter, or `fallback` when absent or bad."""
    try:
        ref q = req.uri.queries
        if key in q:
            var v = reply.param_int(q[key])
            if v >= 0:
                return v
    except:
        pass
    return fallback


@fieldwise_init
struct SpikeHandler(PoolHandler):
    """Implements `func` plus the two `PoolHandler` methods. Nothing else.

    Everything the trait defaults cover — `before_request`, `after_response`,
    the four SSE hooks, `tick`, `ws_message` — is inherited, which is what
    Phase 1 was for. `thread_index` exists so a response can name the thread
    that served it: that is how the measurement tells a pooled run from a
    loop run without trusting its own configuration.
    """

    var thread_index: Int

    @staticmethod
    def make(ctx: PoolContext) raises -> Self:
        return Self(ctx.index)

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path
        if path == "/health":
            return reply.json(200, String("OK"), String('{"status":"ok"}'))
        if path == "/fast":
            return reply.json(
                200,
                String("OK"),
                String('{"route":"fast","thread":', self.thread_index, "}"),
            )
        if path == "/slow":
            var ms = _query_int(req, String("ms"), 200)
            # The blocking call this whole spike is about. `usleep` takes
            # microseconds and caps at one second per call on some platforms,
            # so a long sleep is chunked.
            var left = ms
            while left > 0:
                var chunk = 500 if left > 500 else left
                _ = external_call["usleep", c_int, c_int](c_int(chunk * 1000))
                left -= chunk
            return reply.json(
                200,
                String("OK"),
                String(
                    '{"route":"slow","ms":', ms, ',"thread":',
                    self.thread_index, "}"
                ),
            )
        return reply.json(404, String("Not Found"), String('{"error":"no route"}'))

    def shutdown(mut self):
        pass


def main() raises:
    var config = AppConfig()
    var pool_threads = 0
    var raw = getenv("M0_POOL_THREADS")
    if raw.byte_length() > 0:
        pool_threads = reply.param_int(raw)
        if pool_threads < 0:
            pool_threads = 0

    var server = Server(config.server_config())
    var handler = SpikeHandler(-1)
    var shutdown_fd = install_shutdown_signals()

    if pool_threads == 0:
        print(
            "pool_spike on " + config.address() + " — func on the LOOP",
            flush=True,
        )
        server.listen_and_serve_nonblocking(
            config.address(), handler, shutdown_read_fd=shutdown_fd
        )
        return

    # The pool must outlive the loop: the loop hands it slots and the threads
    # answer through it, so it is constructed here and torn down after
    # `listen_and_serve_nonblocking` returns.
    var pool = OffloadPool(config.server_config().max_connections)
    var threads = MojoPool(pool_threads)
    threads.start[SpikeHandler](pool.addr())
    print(
        "pool_spike on " + config.address() + " — func on "
        + String(pool_threads) + " POOL threads",
        flush=True,
    )
    server.listen_and_serve_nonblocking(
        config.address(),
        handler,
        shutdown_read_fd=shutdown_fd,
        offload_addr=pool.addr(),
    )
    var failed = threads.stop_and_join(pool, JOIN_TIMEOUT_NS)
    if failed > 0 or threads.stragglers > 0:
        print(
            "pool_spike: " + String(failed) + " thread(s) ended badly, "
            + String(threads.stragglers) + " abandoned",
            flush=True,
        )
