# The ASGI executor per core, against uvicorn with uvloop — 2026-10-06

> A design note from the engineering record. The 1.11.0 pre-release run's
> `bench-linux-conclusions` read "ASGI against uvicorn+uvloop, per core" as
> INVERTS, at macOS 1.01x against Linux 0.92x, and the benchmark page said
> uvloop's per-core lead did not survive on Linux. This note measures the
> question in three environments, finds where the per-core cost goes, and
> corrects the page. It follows
> [the-conclusions-on-linux.md](the-conclusions-on-linux.md) and
> [inversion-on-a-constrained-box.md](inversion-on-a-constrained-box.md).

## What was measured

`apps/asgi_bare` under `wrk -t2 -c16` with browser headers, the shape of
the benchmark page's ASGI row, m0serve 1.11.0 at `2746288`. Each run did
three rounds, with the arms alternating within a round and uvicorn
re-measured every round as the drift control. Four arms:

- the default executor, which runs two threads ("pump");
- the same binary with `M0_INVERTED=1`, the Mojo loop inside the asyncio
  loop on one thread;
- `uvicorn --loop uvloop`;
- `uvicorn --loop asyncio`.

The three environments:

- **macOS**: an M4, `scripts/bench_asgi_wrk.sh`.
- **container**: the `m0lin` container, 8 aarch64 vCPUs, the arms of
  `bench_linux_arms.py` with an inverted arm added. The server and wrk
  share the VM's cpus.
- **rented**: a Linode `g6-dedicated-4`, 4 dedicated x86-64 vCPUs (AMD EPYC
  7713), Debian 12. The server was pinned with `taskset` to two vCPUs and
  wrk to the other two, because the 2026-09-09 run on the same plan was
  noisy with both on four. Two passes, six rounds. The account refused the
  8-vCPU plans.

Raw data, the drivers and the profile summaries are in
`bench/results/asgi-per-core-2026-10/`.

## The answer

Per core is requests per second over the cores the server process used.

| environment | pump, per core vs uvloop | inverted, per core vs uvloop | inverted rps / pump rps |
|---|---:|---:|---:|
| macOS | 0.99x (131.7k on 1.60 cores) | **1.31x** (99.9k on 0.91) | 0.76x |
| container | 0.91x (106.3k on 1.34) | **1.42x** (123.9k on 1.00) | **1.17x** |
| rented, pinned | 0.94x (28.6k on 1.22) | **1.27x** (31.7k on 1.00) | **1.11x** |

- **The per-core gap is the pump's second thread, not the executor's
  Python.** The default is level with uvloop per core on macOS and a few
  percent behind on Linux. The one-thread shape is ahead of uvloop per
  core everywhere measured.
- **On Linux at 16 connections, the inverted loop also serves more.** On
  macOS the pump serves more, by spending 0.6 of a second core. At 256
  connections from two cores up, the pump serves more on Linux too
  ([inversion-on-a-constrained-box.md](inversion-on-a-constrained-box.md)).
- **The rented box confirms the container's direction.** Its pinned
  inverted arm ranged 1.17–1.56x of uvloop across rounds, so the size is less
  settled than the sign. Its unpinned run of the standard arms put the pump
  at 0.91x, the container's figure.

## Where the pump's extra CPU goes

macOS `sample`, 10 s against each shape under the same load, self time per
thread normalized per request. Sampling cost the pump some throughput (109k
against 131k) and the inverted loop almost none (101k against 100k).

| per request | pump | inverted |
|---|---:|---:|
| everything but idle waits | 12.0 µs | 8.6 µs |
| client socket reads and writes | 2.9 µs | 2.5 µs |
| **the loop-to-executor datagram handoff** | **1.85 µs** | — |
| CPython | 3.0 µs | 3.6 µs |
| m0serve's own code | 2.3 µs | 1.3 µs |

**The handoff explains about half the gap.** At 16 connections a pass of
the loop carries about one request, so every request pays four syscalls
uvloop never makes:

- the loop's `sendto` of the submit (`flush_lane`);
- the executor's `read` of it;
- the executor's `sendto` of the completion (`complete_many`);
- the loop's `recvfrom` of the completion (`drain_completions_into`).

The 2026-09-08 note priced the whole round trip at 0.43 µs, at 256
connections, where one datagram carries many requests. At low concurrency
it is four times that.

**About another microsecond is the loop's fixed work per pass.** In the
pump a pass runs about once per request, and the Mojo frames are generic
`LoopState` specializations the release build does not name further. The
inverted loop's CPython figure is higher because its pass is itself a
callback inside asyncio.

## Levers, re-priced

- **Take the handoff off the socket where a peer is awake.** The pool's
  ring did this and was worth 13–19 % on bare WSGI
  ([pool-ring-handoff.md](pool-ring-handoff.md)): an in-memory ring, and
  an fd write only to wake a peer that is parked.
  - The completion direction is the simpler half: the executor writes the
    ring, the loop drains it every pass, and wakes it only when it is
    parked, which at c16 is about a third of the time. Its ceiling is
    about 0.7 µs a request.
  - The submit direction needs a check before the executor parks. asyncio
    offers none, and uvloop's selector cannot be wrapped.
  - The channel is the densest ordering seam in the tree:
    [loop-inversion.md](loop-inversion.md) records a job that overtook a
    slot's disconnect tag on it. Anything that leaves it has to keep its
    order against everything that stays. Nothing here is built; it would
    start as an experiment patch measured against this note's numbers.
- **The inversion as a default** stays declined, for the reasons recorded
  on 2026-09-08: they are about switching execution models on detection,
  and the topologies it cannot serve, not about these numbers.
- **The benchmark page** said uvloop leads per core on macOS and that Linux
  answers at or above parity. The macOS figure had already crossed 1.0,
  and two Linux environments now answer below it. The row is corrected to
  this note.
