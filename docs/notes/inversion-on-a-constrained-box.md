# Where the loop inversion wins, measured on a constrained box — 2026-09-08

> A design note from the engineering record. The inversion's per-core edge
> over the pump was known ([loop-inversion.md](loop-inversion.md)); what
> was not known is whether it converts to throughput where cores are
> actually scarce, which is the deployment the edge would matter in. This
> note is that measurement, and the decision it settles.

## The question, and why the Mac could not answer it

On the benchmark box the pump wins. It uses 1.6–1.8 cores to do it, and
on a ten-core laptop those cores are free, so the row that reads
"inverted is 1.16x the pump per core" also reads "the pump serves 1.6x
the requests". Per core is only the deciding number where a core is the
thing you do not have — a `--cpus 1` container, Fly's shared-cpu-1x,
Kubernetes' `limits.cpu: "1"`.

## The instrument

A Linux aarch64 container (colima, an 8-vCPU VM), `m0serve` built from the
tree. The **server** is pinned with `taskset` to N cpus; the **client** is
pinned to a disjoint set, so the client is never the thing being
constrained. CPU comes from `/proc/<pid>/stat` utime+stime deltas, not
`ps %cpu`, which on Linux is an average over the process's whole lifetime
and would report nonsense for an 8-second window. Three rounds, arms
alternated, byte parity asserted across all three arms before any timing.

**Only ratios WITHIN one core count are the signal.** This runs in a VM on
a Mac; the arms share that, so the ratio survives and the absolute numbers
do not. The uvicorn arm is re-measured in every round as the drift
control, and it held within 1.4 % across every core count — which is what
makes the rest of the table readable.

## What it says

| server cores | c16 inverted/pump | c256 inverted/pump | c256 inverted/uvicorn+uvloop |
|---:|---:|---:|---:|
| **1** | 1.02x | **1.14x** | 1.42x |
| 2 | 1.06x | 0.73x | 1.43x |
| 4 | 1.07x | 0.72x | 1.40x |

At one CPU under saturation the inversion serves 138,105 rps against the
pump's 121,578, both at 1.00 core, with a better p99 (2.27 ms against
3.40). From two cores up the pump spreads to 1.59 cores and wins
saturation by 1.38x. At 16 connections the inversion is marginally ahead
everywhere, because the pump cannot use its second thread there anyway
(1.06 cores).

So the rule the numbers give is narrow and clear: **one usable CPU
favours the inversion, two or more favour the pump.**

## A divergence the macOS rows would have hidden

On kqueue at 16 connections the pump beats the inversion by 45 % with a
much better p50 (117 µs against 181). In the Linux container at the same
concurrency the inversion is *ahead*, with a *lower* p50 (139 against
147). The pump's low-concurrency advantage is macOS-specific and does not
reproduce on epoll.

Every artifact on the benchmark page is macOS arm64, and the page says so
— but this is the first measurement that shows the page's platform note
is load-bearing for a conclusion rather than a caveat about absolute
rates.

## The decision: not a default

The bar for promoting the inversion was design item 6 plus a saturation
workload showing a gain. Both are met — item 6 is built
([loop-inversion.md](loop-inversion.md)), and the gain is the table above
plus the Mac artifacts in `bench/results/inversion-2026-09/`. It is still
**not** made a default, and the reasoning is worth recording because the
measurement alone would suggest otherwise:

- The zero-config pool picks a THREAD COUNT within one execution model.
  Auto-selecting the inversion switches execution MODELS on environment
  detection — a different loop architecture, not a different parameter.
- It would put the less-exercised path specifically in the most
  constrained environments, which are the hardest to debug.
- The inversion serves ONE topology (unmounted, pool-free, no
  `--realtime`). An application that later adds a mount, a pool or a hold
  would silently change execution model between deploys.
- The win is 14 % at saturation and 2 % at 16 connections. Real, and not
  large enough to buy the three points above.

What it gets instead is visibility: `--doctor` reports which loop is
resolved (it reported `mode: single` for both before this, so the two
shapes were indistinguishable from the outside), and `M0_INVERTED` is
documented where the other topology knobs are, with the one-CPU guidance
this note measured.

## Two results worth keeping, both negative

**The over-sized pool costs nothing on one CPU.** `pool_cpus` sizes the
zero-config WSGI pool from `sysconf(_SC_NPROCESSORS_ONLN)`, so a process
pinned to one CPU still gets eight handler threads, and the obvious
reading is that seven of them are waste. Measured on bare WSGI pinned to
one CPU, it is not:

| arm | c16 | c256 | RSS |
|---|---:|---:|---:|
| zero-config, 8 threads | 77,097 | **155,740** | 52.8 MB |
| `--blocking-threads 1` | 77,738 | 142,159 | 35.5 MB |

0.99x at 16 connections and **1.10x at 256** — a gain. A pool thread's
parallelism is WAITING, so how many views may wait at once has nothing to
do with the CPU budget, and the elastic wake rules
([elastic-pool.md](elastic-pool.md)) are what stopped the extra threads
costing anything. The cost is memory, about 17 MB for seven more bridges.
`pool_cpus` therefore keeps the online count deliberately, and its
docstring carries this measurement.

**The executor's datagram handoff is smaller than it looked.** The pool's
job and completion handoff moved into memory
([pool-ring-handoff.md](pool-ring-handoff.md)) and was worth +13–19 % on
bare WSGI; the executor's did not move and is the obvious next candidate.
Priced from the per-thread figures — at 256 connections both loops are
saturated and the ASGI loop costs 5.27 µs per request against the WSGI
loop's 4.84 — the whole handoff is 0.43 µs. But that is the ROUND TRIP,
and only the completion direction can leave the socket: the executor
parks in asyncio's selector, which nothing but an fd can wake, so the
submit direction keeps its datagram whatever else changes. What is
actually available is about half of 8 %, in the seam whose ordering rules
are the densest in the tree. Written down as a decision rather than left
as an omission.
