"""The job that links MAX's parallel runtime, shared by the two probes.

`apps/host_parallel/probe.mojo` (the Mojo host, SPEC E32) and
`apps/serve_parallel/mount/m0serve_mount.mojo` (an m0serve mount, E33)
answer the same two routes from it, so the refusals on both hosts are
measured against one binary shape: `from max.algorithm import parallelize`
is what puts `libAsyncRTMojoBindings` on the link line, and this is the
one place it is imported.

`work`'s capture list -- `{var out}` -- is what a `parallelize` closure
needs on Mojo 1.1: the closure captures the buffer by value and writes
through it. `timed` stamps `x-thread` (the pool thread, or -1 for a loop)
and `x-pid`, so a probe can say which instance and which process answered.
"""

from std.ffi import external_call
from std.math import sqrt
from std.memory.alloc import unsafe_alloc
from std.time import perf_counter_ns

from max.algorithm import parallelize

from lightbug_http import HTTPResponse
from m0_http import reply


comptime WORK = 64
comptime INNER = 100_000


def compute(parallel: Bool) -> Float64:
    """The job, spread or not; the sum of every item's result."""
    var out = unsafe_alloc[Float64](count=WORK)

    def work(i: Int) {var out} -> None:
        var acc = Float64(0)
        for k in range(INNER):
            acc += sqrt(Float64(k + i))
        out[unsafe_offset=i] = acc

    if parallel:
        parallelize(work, WORK)
    else:
        for i in range(WORK):
            work(i)
    var total = Float64(0)
    for i in range(WORK):
        total += out[unsafe_offset=i]
    out.unsafe_free()
    return total


def timed(parallel: Bool, thread: Int) -> HTTPResponse:
    var t0 = perf_counter_ns()
    var total = compute(parallel)
    var us = (perf_counter_ns() - t0) // 1000
    var resp = reply.html(String(
        "par=" if parallel else "ser=", us, "us sum=", Int(total) % 1000,
    ))
    resp.headers["x-thread"] = String(thread)
    # Which process answered: under `--workers 2 --spawn-workers` the m0serve
    # probe insists BOTH exec'd images served a parallelize.
    resp.headers["x-pid"] = String(Int(external_call["getpid", Int32]()))
    return resp^
