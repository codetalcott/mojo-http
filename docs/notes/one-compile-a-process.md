# One compile a process (SPEC E44)

m0serve runs its Python shim — WSGI's `start_response`, the ASGI cycle,
the executor's pump; `packages/m0-wsgi/shim/m0_shim.py`, 93,842 bytes —
in a namespace of its own for every serving thread: the loop's handler,
each `--blocking-threads` thread, each asyncio executor, each `--threads`
loop. `PyBridge` built that namespace with `exec(SHIM_SOURCE, ns)`, so it
parsed and compiled the source once per thread, and `detect_protocol`
parsed it once more per application at startup. The shim is now compiled
once per interpreter and each namespace executes a copy of that code of
its own.

## What a parse cost

Measured on an Apple M4 (macOS 27.2.1), CPython 3.14.7, Mojo 1.2.0, with
tracemalloc tracing one `PyBridge()` at a time, nine in one process; the
time is the same two operations in Python with nothing traced, the median
of 30 (tracing slows them two to three times):

| each bridge after the first | allocated at the peak | kept | time |
| --- | --- | --- | --- |
| parsing the source | 4.17 MB | 0.13 MB | 4.3 ms |
| loading the compiled code | 0.13-0.15 MB | 0.10-0.13 MB | 0.12 ms |

The first bridge costs the same either way, 4.47 MB at the peak and
0.57 MB kept, since it also runs the shim's first imports. That is the
0.56 MB [a-loop-keeps-slots-for-requests](a-loop-keeps-slots-for-requests.md)
gave as what a compile keeps; each later one kept 0.13.

A parse freed about 4 MB as it finished, its peak less what it kept, and
how much of that the system allocator kept dirty in its small zone was the
allocator's placement, not anything the server asked for. So an idle
server's memory moved in 3.6 MB steps from one start to the next, which is what failed the pool's
idle-memory gate on CI (that note's last section) and why the gate takes
each cell's least of three starts.

## Shared code or a copy

Two ways to compile once: execute ONE code object in every namespace, or
keep the compiled code marshalled and give each namespace a fresh copy, as
loading a `.pyc` does. Shared is cheaper still (0.02 MB a namespace),
but CPython 3.14's specializing interpreter caches a global's lookup
against one globals dict's keys and an attribute's against one class, and
each namespace has its own dict and its own classes. Measured
on the shim's own `run` with a trivial WSGI application, 200,000 calls,
seven runs interleaved:

| namespaces, calls before the next | own code (as before) | shared | a copy |
| --- | --- | --- | --- |
| 2, one | 552 ns | 576 ns (1.044) | |
| 8, fifty | 551 ns | 575 ns (1.043) | |
| 8, one | 547 ns | 568 ns (1.039) | 545 ns (0.996) |

Shared code cost `run` 4 to 5 % even when each namespace ran fifty calls
in a row: the caches never settle. A copy runs as the namespace's own code
did, so each namespace loads one. (The free-threaded build keeps its
specialized bytecode per thread; it was not measured.)

## The change

`shim_code()` in `packages/m0-wsgi/src/bridge.mojo` is the one place the
shim is compiled. The first call compiles `SHIM_SOURCE` under the name
`exec` gave it, `<string>`, so a traceback through the shim reads as it
did, and keeps `marshal.dumps` of the code (66 KB) in the dict CPython
keeps per interpreter for extensions' state, which Python code cannot
reach: an application sees nothing new in `sys.modules` or `builtins`.
Every call, the first included, returns `marshal.loads` of it. Two threads
building their first bridges at once may each compile; `setdefault` keeps
the first stored and both load it. `PyBridge` and `detect_protocol` both
execute `shim_code()`.

`packages/m0-wsgi/test/test_bridge_build.mojo` holds the three rules, each
broken once and caught by the test written for it:

- three bridges after a process's first must each peak under 1 MiB: the
  second read 4,168,880 B before the change, and 4,170,003 with the cache
  never hit;
- a second protocol detection, a mount's, under the same bound: 4,168,856 B
  with detection parsing again. The first detection is not the one traced,
  since it imports `inspect`, which alone peaks at 1.5 MB;
- two bridges share no namespace, function, code object or lifespan state:
  sharing the code object fails it.

## The server

Measured on the same M4 on 2026-11-18: `bin/m0serve` built from main at
2e397d44 and from the change, the two binaries alternating start by start,
each start fresh. The shape is the pool-share gate's eight-thread cell:
`hold_app` under `--realtime`, `--blocking-threads 8`, `--max-connections
16384`. The footprint is read as `scripts/probes/pool_idle_rss.py` reads
it, the median of five reads after a second's settle, and CPU is
`ps -o cputime` at the read. `mediaanalysisd` held 1.2 cores throughout.

| eight threads, 16384 connections | before | after |
| --- | --- | --- |
| idle footprint, quiet, 10 starts | 41.0-41.8 MB | 39.0-39.4 MB |
| idle footprint, 14 spinning processes, 30 starts | 45.4-59.5 MB | 39.2-39.9 MB |
| CPU at idle, quiet (median) | 0.07 s | 0.03 s |
| CPU at idle, 14 spinning processes | 0.11-0.13 s | 0.04-0.05 s |

Quiet, a server holds 1.75 MB less (medians 41.02 and 39.27 MB). Under
load the before column climbs in steps and the after column does not
move. The CPU saved is the parses after the first, 4.3 ms each on a
quiet machine.

The pool-share probe itself (`--counts 1024,16384 --threads 8 --rounds
3`), six runs of each binary under six spinning processes:

| six runs, 18 rounds | before | after |
| --- | --- | --- |
| a round alone past 128 B a slot | 5 of 18 | 0 of 18 |
| the median of the rounds' slopes past 128 | 2 of 6 | 0 of 6 |
| the least of three past 128 | 2 of 6 | 0 of 6 |
| one round's share, lowest to highest | -674 to 751 B | -9 to 55 B |
| the eight-thread cell at 16384, every start | 41.7-52.2 MB | 39.3-39.5 MB |

`smoke-max-connections` still judges each cell on its least of three
starts, which costs CI's macOS runner 42 s more than one round did.

Throughput does not move: bare WSGI `/` on eight pool threads, `wrk -t2
-c16` for 5 s after 2 s, the binaries in the order A B B A A B under
`M0_QOS=1`. Before: 209,262-211,164 requests a second (median 210,611).
After: 208,197-212,014 (median 210,092), 0.998 of before. Each namespace
runs its own code objects, as it did before the change.
