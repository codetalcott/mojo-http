# WSGI against gunicorn, the keep-alive tail, and the case for the pool — 2026-08-16

> A design note from the engineering record, moved out of
> [WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md) on 2026-11-06 and kept as
> written. The page itself now holds the current tables; the runs that led
> to them live here.

This note records the WSGI path's first runs against gunicorn on a 4-core
Linux container, the keep-alive tail that `ab` and `wrk` read differently,
the mixed-workload run that justified the handler pool and the same run
with the pool on, what the header work bought a Django request, and the
three fixes behind the early tails. Every figure is the record of its date.

First measured 2026-08-16, once the prefork concurrency story existed. Before
that, `HTTPService.func` served one request at a time per process and any
throughput claim would have been noise about the wrong bottleneck. Re-measured
the same day after each of three serving changes this document motivated: the
shared pre-fork listener, the move to the non-blocking event loop, and the
leak-free bridge.

Re-measured again 2026-08-18 after the server-layer work in
[the-raw-hot-path.md](the-raw-hot-path.md) — the syscall-budget pass and
the span-based headers. The tables below are from that session; the earlier
absolute numbers are not comparable to them (see the warning under Setup).

## Setup

Same Django project (`apps/django_wsgi/djangoproj`, `DEBUG = False`, no
middleware), same worker counts, same machine, same load generator.

- 4-core Linux container, everything (server + load) on one box. **The
  container is shared and drifts hard — never compare absolutes across
  sessions, or even across distant rounds of one session.** Measured
  directly on 2026-08-18: an untouched binary produced 2,035 req/s in one
  round and 3,406 in another, 1.7x from container load alone. Every table
  row was therefore measured by alternating against its comparator inside
  one session, and the ratios are what carry meaning.
- mojo-http: `bin/m0serve` (`poe build-serve`) serving `apps/django_wsgi`
  (Mojo 1.0, the pin on that date), `M0_WORKERS=N`. Workers accept from one
  listener bound before the fork, the same model gunicorn uses — a busy
  worker simply doesn't accept, so connections land on free workers. (An
  earlier per-worker `SO_REUSEPORT` design measured ~20% lower at 4 workers,
  because REUSEPORT hashes connections to workers with no regard for load —
  and on macOS it does not distribute at all.) Each worker serves through the
  non-blocking event loop; the history below explains why.
- gunicorn 26.0.0, default sync workers, `-w N`, `--log-level warning`
- wrk: 2 threads, 16 connections, 10 s runs after a 5 s warm-up, against `/`
  (a plain-text Django view). The 2026-08-18 rows send a browser-shaped
  request — twelve headers (`User-Agent`, `Accept`, `Accept-Language`,
  `Accept-Encoding`, `Cache-Control`, `Referer`, the `Sec-Fetch-*` set) —
  because wrk's default sends only `Host`, and header count is the variable
  the request path is most sensitive to.

Two client modes, because the servers differ in one relevant way: gunicorn's
sync worker closes every connection (it does not implement keep-alive), while
mojo-http keeps connections alive. `Connection: close` is the apples-to-apples
comparison; keep-alive is what a reverse proxy in front of mojo-http would
actually do.

## Results

Measured 2026-08-18, one worker and two, against a **browser-shaped request**
— twelve headers, the sort a real client sends. That choice matters and is
justified in the next section.

Requests per second, wrk p50 / p99 in parentheses:

| Workers | mojo-http (keep-alive) | mojo-http (close) | gunicorn        |
|--------:|-----------------------:|------------------:|----------------:|
| 1       | 4,279 (3.5 / 8.8 ms)   | 4,186 (3.7 / 5.8 ms) | 3,140 (4.8 / 8.9 ms) |
| 2       | 8,166 (1.9 / 84 ms)    | 8,640 (1.8 / 3.6 ms) | 5,749 (2.6 / 113 ms) |

**1.36x gunicorn at one worker, 1.42x at two** (1.50x comparing close mode,
the apples-to-apples pairing, since gunicorn's sync worker has no
keep-alive). p50 is well below gunicorn's at both worker counts.

Two things in that table are worth reading carefully rather than skimming:

- **Close mode is not slower than keep-alive here, and its tail is far
  better** (3.6 ms vs 84 ms p99 at two workers). Both servers show a fat
  keep-alive p99 at two workers because 16 persistent connections pin
  themselves across 2 processes and queue behind each other; gunicorn's is
  worse still at 113 ms. This is queueing, not per-request cost — the p50s
  are 1.8-1.9 ms.
- **Do not compare these absolutes to the 2026-08-16 table above.** The
  container drifts hard: during this very session the same before-binary
  measured 2,035 req/s in one round and 3,406 in another, an untouched
  binary moving 1.7x on container load alone. Every comparison here was
  taken by alternating the two binaries within one session, and the ratios
  are what carry meaning.

## What the threads-vs-prefork table says

The table, measured 2026-08-22, is on
[WSGI and ASGI performance](../WSGI_PERFORMANCE.md#threads-vs-prefork-on-one-free-threaded-interpreter).

What the table says, and what it does not:

- **Threads are at throughput parity with prefork.** 0.92–1.05x across the
  eight pairings, inside the round-to-round spread. This is the expected
  answer for Stage A: each thread runs the same event loop and the same
  bridge a worker does, so per-request cost is unchanged; what the mode
  changes is the process model. It is also the answer that matters — the
  free-threaded build's single-thread overhead did not eat the parallelism.
- **One process costs ~60% of N processes.** 48 MB against 79–83 MB at four
  loops; the application is imported once and the interpreter's heap is
  shared. (The 94 MB prefork figure in round 2 at two workers is an outlier
  — a respawned or lingering worker caught by the process-tree sum — and is
  reported rather than dropped.)
- **~3.5x gunicorn at four loops, ~3.3x at two**, on the same free-threaded
  interpreter. gunicorn's sync workers gain nothing from free-threading
  (they are processes), so this is the same ratio shape as the 3.13 table,
  measured through a different tool.
- **The keep-alive tail did not reproduce here.** p99 sits at 2–4 ms for
  both mojo-http modes where the 2026-08-18 `wrk` run saw 84 ms at two
  workers. `ab -k` keeps 16 connections open the same way, so the
  difference is most likely load shape (ab's fixed request count and
  slower client) rather than a server change — and the pinning mechanism
  is unchanged: a keep-alive connection still belongs to whichever loop
  accepted it, in both modes. The honest statement is that this run did
  not excite the tail, not that the tail is gone; Stage B (built as
  `--blocking-threads`) remains the fix for it, and a `wrk` run on the
  same box is the next measurement worth making. **That run has now happened — the next section
  is the one that settles it, and it revises this bullet's conclusion.**
- **Not in the table:** 3.13 vs 3.14t. Every row is 3.14.7t; the 3.13
  numbers above were a different day, tool and container and do not
  chain to these.

## The keep-alive tail under wrk, and the Stage B decision

`ab` could not settle the tail question, because `ab` is the tool that
failed to provoke it. This is the `wrk` twin: same box (M4, 4P+6E), same
**CPython 3.14.7t with the GIL off**, same `apps/django_wsgi` hello route,
same twelve-header browser request. `wrk -t2 -c16 -d10s --latency`, three
rounds, keep-alive only. `scripts/bench_wsgi_tail_ka.sh` is the run.

Requests/sec, with the latency distribution wrk reports:

| config | round 1 | round 2 | round 3 |
|--------|--------:|--------:|--------:|
| `--workers 2` | *(row lost — see below)* | 14,087 · p99 **5.74** ms · max 46.0 | 14,978 · p99 **2.22** ms · max 9.9 |
| `--threads 2` | 14,814 · p99 **2.21** ms · max 13.1 | 14,023 · p99 **2.89** ms · max 18.5 | 14,887 · p99 **2.19** ms · max 12.2 |
| `--workers 4` | 24,087 · p99 **1.61** ms · max 10.3 | 18,614 · p99 **52.21** ms · max 184.6 | 20,829 · p99 **1.75** ms · max 10.6 |
| `--threads 4` | 22,909 · p99 **1.65** ms · max 14.2 | 20,786 · p99 **1.82** ms · max 12.5 | 20,201 · p99 **2.02** ms · max 12.6 |
| granian `bt=2` | 28,446 · p99 0.94 ms | 28,042 · p99 1.03 ms | 27,199 · p99 1.08 ms |
| granian `bt=4` | 31,967 · p99 1.01 ms | 30,534 · p99 0.94 ms | 29,921 · p99 0.96 ms |

Granian 2.8.1, one process, N blocking threads, on the same interpreter.
Byte parity was checked before timing: both servers return the identical
30-byte response.

### What it says

- **The 84 ms tail did not reproduce as a property of the design.** Typical
  keep-alive p99 is **1.6–2.9 ms** across both modes and both sizes.
- **One excursion in seventeen valid rows**: `--workers 4`, round 2, p99
  52 ms and max 185 ms. It did not recur in the other two rounds of that
  configuration, and `--threads` never produced one in five rows. So the
  tail is real and rare — and it appeared in **prefork**, the mode that
  already has N processes with N accept queues. That is the opposite of
  what "connections are pinned to one loop" predicts.
- **Threads and prefork are indistinguishable on the tail**, and at
  throughput parity under `wrk` too (0.95–1.0x), which confirms the `ab`
  row with a second tool.
- **Granian was 1.4–2.0x faster than either mode** in this run, with a
  consistently tighter p99, on the same free-threaded interpreter and a byte-identical
  response. That gap is the honest headline of this table.

### Stage B: this benchmark could not settle it — see the mixed-workload row

Stage B (built as `--blocking-threads`) is an acceptor loop feeding a
Python thread pool with deferred responses — ~8 touchpoints in `event_loop.mojo`. It exists for two
things: **per-request balancing** and **slow-view isolation**.

This benchmark cannot speak to the second at all. Its view is trivial, so
there is never a slow request for a fast one to be stuck behind — which is
precisely the failure Stage B removes. And on the first, which it *can*
measure, there is no systematic tail to fix: p99 sits at 1.6–2.9 ms, and
the single excursion was in the mode Stage B would not change.

So the gate became a **mixed-workload run** — a deliberately slow view
alongside fast ones on the same loop. **That run has since happened, and it
justifies Stage B decisively**; see "A slow view strands the connections
pinned behind it" below. The paragraph that used to stand here recorded a
no-go on this table's evidence alone, which was the wrong question asked
well: a hello route cannot produce the failure Stage B fixes.

### A methodology trap, recorded because it nearly produced a wrong answer

The first `wrk` table (`scripts/bench_wsgi_tail.sh`, which measures
keep-alive *and* close-per-request in each row; removed from the tree on
2026-09-28, last in commit `a78f189`) reported a clean 8–10x tail
gap between threads and prefork — `--threads` p99 17–22 ms against
prefork's 2.3 ms — and five rows with no numbers at all. Both were the
same artifact.

macOS's ephemeral port range is 49152–65535: **16,384 ports**. A
close-per-request run at ~16k rps for 10 s opens ~160k connections, and
every one lands in `TIME_WAIT` for the 15 s MSL. Within one row the range
is exhausted, so the *next* row's keep-alive run cannot open even its 16
connections — and every keep-alive row except the very first ran
immediately after a close run. The rows that reported nothing were
`connect 16` failures; the rows that reported a tail were measuring port
pressure, not the server.

`bench_wsgi_tail_ka.sh` is the fix: keep-alive only, a cooldown between
rows, a `TIME_WAIT` drain gate before the first row, and — most
importantly — **wrk's `Socket errors` line is reported in every row**, with
a `<-- MEASUREMENT FAILED (ports)` marker, so a failed measurement can
never again be read as a slow server.

The same artifact is why **gunicorn is not in this table**. Its sync worker
answers `Connection: close` on every response, so a keep-alive benchmark
against it is pure connection churn and it exhausts the port range faster
than anything else — the first run scored it at 81 and 0.20 rps. Measured
fresh, it does 3,263 rps, consistent with the `ab` table's 3,748. A server
that cannot speak keep-alive does not belong in a keep-alive tail table;
the `ab -k` row above is the right place for that comparison.

## A slow view strands the connections pinned behind it

This is the mixed-workload measurement the `wrk` section named as Stage B's
gate, and it is the one that settles it. `scripts/bench_mixed_workload.sh`,
3.14.7t, two rounds. Foreground: `wrk -t2 -c16 -d10s` on Django's hello
route. Background: N concurrent requests to `/slow?ms=200`, re-issued for
the whole run. All three N levels run against **one warm server** per
configuration, so the baseline is the same process, warmed the same way,
seconds before the loaded rows.

Fast-route p99, by how many slow requests are in flight:

| configuration | slow=0 | slow=1 | slow=2 |
|---------------|-------:|-------:|-------:|
| `m0serve --workers 4` | 1.62 / 1.75 ms | **193.1 / 195.3 ms** | **198.5 / 201.4 ms** |
| `m0serve --threads 4` | 1.61 / 1.97 ms | **195.2 / 194.2 ms** | **201.6 / 203.4 ms** |
| `granian --blocking-threads 4` | 0.96 / 0.96 ms | 0.93 / 0.97 ms | 1.22 / 1.15 ms |

Both rounds shown. What it says:

- **One slow view raises fast-request p99 by ~120x**, from 1.6 ms to
  ~194 ms — approximately the slow view's own hold time.
- **p50 does not move at all** (617 µs → 617 µs at `--workers 4`). This is
  not general slowdown; it is a subset of connections stopped dead. With
  four loops and 16 keep-alive connections, the ~4 pinned to the busy loop
  wait out the whole hold while the other twelve are served normally. p90
  tracks that arithmetic: 82 ms at slow=1, 133 ms at slow=2.
- **Stage A does not help.** `--threads` is affected identically, which is
  expected and worth stating plainly: a keep-alive connection belongs to
  the loop that accepted it in *both* modes. Threads changed the process
  model, not the pinning.
- **A thread pool removes it entirely.** Granian's p99 is flat under the
  same load — 0.96 → 0.93 → 1.22 ms. `--blocking-threads` *is* the Stage B
  architecture: an acceptor handing work to a pool, so no connection is
  hostage to whichever request a particular loop happens to be running.

**Stage B is justified.** Not by a tail that a fast route failed to
produce, but by the failure it was actually designed for, measured directly
— and with a working reference implementation of the same design showing
what it buys. **It has since been built** (`--blocking-threads N`); the next
section is the same measurement with the flag on, and this one is now its
control.

### Three harness bugs, recorded because each produced a confident wrong answer

- **`seq 1 0` prints "1" and "0" on BSD/macOS.** `start_slow 0` therefore
  launched *two* slow loops and the baseline silently carried the same load
  as the treatment rows. Every row looked identical (p99 196 / 191 / 195 ms)
  — which reads exactly like a null result. Had it not been checked against
  the ~1.7 ms this configuration shows in the `wrk` table above, the
  conclusion would have been "slow views harm nothing" and Stage B would
  have been closed on a broken control.
- **Restarting the server per row** gave every row its own Django lazy-import
  transient, which is a 200 ms hole indistinguishable from a slow-view tail.
  One warm server per configuration fixes it; the script now also greps the
  supervisor log for crash/respawn, for the same reason.
- **Forgetting the post-swap rebuild reports as `never healthy`, on every
  row.** "Reproducing" below already says to rebuild `bin/m0serve` inside the
  swap; what is worth recording is what it looks like when you do not. The
  binary dies in `dyld` before reaching `main`, so the benchmark sees a port
  that never answers and prints `never healthy` — which reads like a port
  conflict or a bad flag, and the actual message
  (`Library not loaded: @rpath/libKGENCompilerRTShared.dylib`) is in a server
  log nobody opens when the row simply says "unhealthy". `py-canary` is immune
  by accident: every one of its `poe smoke-*` tasks declares `build-serve` as a
  dependency, so the rebuild happens whether or not anyone remembered it. A
  hand-driven benchmark script has no such dependency and must do it itself.

## Stage B, measured: the pool removes it

The section above is the *before*. This is the same script, the same
`/slow?ms=200`, and the same three slow levels, with `--blocking-threads 4`
added to each configuration — the flag as the only variable, both halves in
one run so the control has to keep failing for the treatment to mean
anything.

**Different machine from the table above** (an M4, 4P+6E, macOS, 3.14.7t, two
rounds) so the absolutes are not comparable to the Linux-container rows; the
rows here are comparable to *each other*, which is the whole design of the
run.

**Superseded 2026-08-26 by an artifact.** The numbers in this section were
recorded before `bench_record.py` existed and are kept as the narrative of
how the pool was justified; the current, machine-readable version is
rendered on [BENCHMARKS.md](../BENCHMARKS.md#slow-view-isolation) from
`bench/results/mixed-workload-*.json`. The shape reproduced exactly —
~1 ms → ~195 ms without the flag, flat with it, in both execution modes.

At the same shape, one worker with four handler threads, Granian's row and
m0serve's now read the same
([BENCHMARKS.md](../BENCHMARKS.md#slow-view-isolation)).

Fast-route p99, by how many slow requests are in flight (both rounds):

| configuration | slow=0 | slow=1 | slow=2 |
|---------------|-------:|-------:|-------:|
| `--workers 4` | 0.99 / 1.15 ms | **190.4 / 190.7 ms** | **196.1 / 195.8 ms** |
| `--threads 4` | 1.14 / 1.16 ms | **194.5 / 195.6 ms** | **200.6 / 200.6 ms** |
| `--workers 4 --blocking-threads 4` | 2.51 / 2.58 ms | 2.29 / 2.38 ms | 2.30 / 2.44 ms |
| `--threads 4 --blocking-threads 4` | 1.78 / 2.12 ms | 1.78 / 1.83 ms | 1.88 / 1.85 ms |

- **The pool removes the failure, in both execution modes.** p99 does not
  move as slow load is added — it is the same 2 ms with two slow views in
  flight as with none. The rows without the flag, measured minutes apart on
  the same machine, still climb to ~195 ms. That is the gate this work was
  given, and it is the shape granian's `--blocking-threads` row has.
- **p90 is the clearer tell.** Without the pool it goes 0.70 ms → 78 ms →
  133 ms: by two slow views, more than a tenth of all requests are stopped
  dead, which is what "the connections pinned to the busy loop" means
  arithmetically. With the pool it stays ~1 ms throughout.
- **It cost throughput in this run, and the cost was not the same in both
  modes.** At slow=0, two-round means: prefork gave up **7.3%** (34.9k →
  32.3k rps) and threads **21.3%** (32.7k → 25.7k). The 14% between them
  is *not* explained by thread count: `--threads 4 --blocking-threads 4` is
  four loops plus sixteen handler threads, and `--workers 4 --blocking-threads 4` is four
  processes of five — **twenty threads either way**, on four performance
  cores. What differs is four independent interpreters against one shared
  between twenty threads. See "Sizing the pool" below, which also says why no
  startup warning fires on a large pool.

## What the server-layer work bought the WSGI path

The span-based headers landed a **+72%** throughput win on `apps/hello`,
where the handler does nothing. The obvious question is how much of that
survives once a real Django request is in the way. Two things were measured
rather than assumed.

**The win scales with header count, as predicted.** The old `Headers`
allocated per header to fill and per lookup to probe, so its cost was a
function of how many headers a request carried. Alternating A/B against the
parent commit, one worker:

| request shape          | before | after | delta   |
|------------------------|-------:|------:|--------:|
| wrk default (1 header) | 2,822  | 2,979 | **+5.6%**  |
| browser-shaped (12)    | 2,052* | 2,308*| **+13.8%** |

\* the browser rows are the mean of four alternating rounds; two ran during
a slower container period (~2.0k) and two during a faster one (~3.4k), which
is why the ratio is quoted rather than the absolutes.

Twelve headers roughly **2.4x the benefit** of one. Anything measuring this
server with a minimal synthetic request is understating what real traffic
gets.

**But it is diluted, and that is the honest headline.** +72% on hello
becomes ~+14% on Django, because at ~3-4k req/s each request spends a few
hundred microseconds inside CPython and Django — the server layer is a
small and now-smaller slice of it. The header work is worth more to
`apps/notes_api` and the Datastar apps, where the handler is Mojo, than it
is here. The place to spend effort on *this* path remains the bridge and the
worker count, not the request parser.

## History: three fixes, and what the tails actually were

**Keep-alive p99 ~140 ms — the blocking accept loop.** The first benchmarked
configuration served each worker through the blocking accept loop, which
drains one accepted connection's keep-alive requests exclusively until the
idle timeout or the `max_keepalive_requests` cap closes it. Under 16
persistent connections that measured p50 ~245 µs but p99 ~140 ms: fifteen
connections queued while one was drained. Moving the workers onto the
non-blocking event loop (the same loop SSE already requires) replaced
connection-exclusive draining with multiplexing after every response, and
keep-alive collapsed to single-digit p99 while throughput rose at every
worker count.

**Close-mode p99 ~80–150 ms — a per-request reference leak.** After the loop
switch, `Connection: close` runs showed a wild tail that keep-alive runs
mostly didn't. Chasing the obvious suspect (the edge-triggered accept path)
was wrong twice over: server-side timing (`M0_ACCESS_LOG=true`) showed
requests completing in p99 298 µs *inside* the loop while clients waited
45+ ms, and a level-triggered listener changed nothing. The discriminating
observation was that only *aged* processes showed the tail — and the worker's
RSS was growing ~2.3 KB per request, without bound.

The growth was a CPython reference leak in Mojo 1.0's `PythonObject` interop:
every call *argument* and every `__setitem__` *value* leaks one reference
(measured directly — a dict passed to a no-op Python function 1000 times ends
with its refcount 1000 higher). The old bridge built the environ dict via
Mojo setitems and passed it as a call argument, so every request pinned its
environ, `wsgi.input`, and response body forever. The leaked heap made
CPython's gen-2 collections progressively slower — one ~200 ms GC pause on
the event loop stalls every queued connection at once, which is exactly a
1% tail at 5k req/s. Close mode amplified it only because connection churn
runs closer to CPU saturation, where a single pause backs up more clients.

The fix (`m0-wsgi/src/bridge.mojo`) restructures the boundary so no
per-request Python object crosses through a leaky operation: Mojo serializes
the request into a persistent Python-side `bytearray` through a raw pointer,
and a zero-argument `handle()` builds the environ natively, runs the
application, and returns `(status, headers, body)` — zero-argument calls and
call results are measured leak-free. RSS over 500k requests now moves ~360 KB
total, and `smoke-django` fails if 10k requests grow the worker by more than
12 MB. The same rewrite made the shim call `close()` on the application's
result iterable, which PEP 3333 requires and the old shim skipped.

**What remains.** At one worker under saturation, the median close-mode
request still waits ~2–3 ms: a synchronous view occupies the process, so a
16-client closed loop queues about one batch deep. That is the design (more
workers absorb it), not a defect. Separately, the first seconds after a
keep-alive fleet aborts can show a handful of ~220 ms requests — the
signature of kernel TCP retransmission (RTO floor 200 ms) during mass
teardown, visible server-side and identical with the leak fixed; it is a
boundary artifact of switching load patterns, not steady-state behavior.
