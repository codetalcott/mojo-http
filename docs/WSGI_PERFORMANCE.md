# WSGI performance: mojo-http vs gunicorn

First measured 2026-08-16, once the prefork concurrency story existed. Before
that, `HTTPService.func` served one request at a time per process and any
throughput claim would have been noise about the wrong bottleneck. Re-measured
the same day after each of three serving changes this document motivated: the
shared pre-fork listener, the move to the non-blocking event loop, and the
leak-free bridge.

Re-measured again 2026-08-18 after the server-layer work in
[SERVER_PERFORMANCE.md](SERVER_PERFORMANCE.md) — the syscall-budget pass and
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
  (Mojo 1.0, the `uv.lock` pin), `M0_WORKERS=N`. Workers accept from one
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

## Threads vs prefork, on one free-threaded interpreter

Measured 2026-08-22 on an M4 (4P+6E), **CPython 3.14.7t with the GIL off**
for all three servers — mojo-http's prefork mode, its threaded mode, and
gunicorn 26.1.0 — serving `apps/django_wsgi`'s hello route with the same
browser-shaped request as above. ApacheBench this time (`ab -c16 -n20000`,
with `-k` for keep-alive), because it ships with macOS and `wrk` does not;
the table is ratios within one session, which either tool gives. Two
alternating rounds; both shown, because the spread *is* the finding's
error bar. `scripts/bench_wsgi_modes.sh` is the run.

Requests per second, `ab` p50 / p99 in ms, RSS of the whole process tree:

| loops | `m0serve --workers N` | `m0serve --threads N` | `gunicorn -w N` | RSS prefork / threads / gunicorn |
|------:|----------------------:|----------------------:|----------------:|---------------------------------:|
| 2, keep-alive | 12,759 · 14,734 (1 / 2–3) | 11,055 · 14,127 (1 / 3–4) | 3,748 · 4,096 (4 / 8–14) | 44–94 MB / 25–38 MB / 53 MB |
| 2, close      | 8,777 · 12,599 (1–2 / 2–5) | 7,984 · 13,128 (1 / 2–8) | 4,075 · 3,979 (3–4 / 9–12) | |
| 4, keep-alive | 21,458 · 20,565 (1 / 2) | 20,587 · 21,638 (1 / 2) | 5,841 · 6,178 (2 / 5–7) | 79–83 MB / 48–49 MB / 92–93 MB |
| 4, close      | 16,480 · 16,469 (1 / 3) | 16,303 · 16,088 (1 / 3) | 5,977 · 6,129 (2 / 4–6) | |

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
  not excite the tail, not that the tail is gone; Stage B (ROADMAP.md)
  remains the fix for it, and a `wrk` run on the same box is the next
  measurement worth making. **That run has now happened — the next section
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
- **Granian is 1.4–2.0x faster than either mode**, with a consistently
  tighter p99, on the same free-threaded interpreter and a byte-identical
  response. That gap is the honest headline of this table.

### Stage B: this benchmark could not settle it — see the mixed-workload row

Stage B (ROADMAP.md) is an acceptor loop feeding a Python thread pool with
deferred responses — ~8 touchpoints in `event_loop.mojo`. It exists for two
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
keep-alive *and* close-per-request in each row) reported a clean 8–10x tail
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

## Where the Granian gap lives: the bridge, not the HTTP layer

The table above measures Granian at 1.4–2.0x either mode on Django. That is
one number for two possible causes with completely different fixes, so this
section splits it into three rows that differ by exactly one layer.
`scripts/bench_layer_split.sh`, 3.14.7t, `wrk -t2 -c16 -d10s`, three rounds.

Rows 2 and 3 run the SAME application — `apps/wsgi_bare`, a plain PEP 3333
callable with no third-party imports — so the Python work is identical. The
bare app rather than Django on purpose: Django's middleware is a large
constant *both* servers pay, and it compresses the very ratio being
resolved. All three roots return 13 bytes of `text/plain`, and byte parity
between m0serve and Granian is asserted before any timing.

| row | what it adds | rps (3-round mean) | p50 |
|-----|--------------|-------------------:|----:|
| `apps/hello` | mojo-http HTTP layer, **zero Python** | **78,290** | 178 µs |
| `m0serve` + bare, 1 worker | …plus the WSGI bridge | **12,421** | 1.18 ms |
| `granian` + bare, 1 worker | Granian's HTTP layer + its PyO3 bridge | **124,642** | 109 µs |
| `m0serve` + bare, 4 workers | | 34,995 | ~400 µs |
| `granian` + bare, 4 workers | | 99,187 | 130 µs |

(`apps/hello` has no `WorkerSupervisor`, so it is single-process by
construction and `M0_WORKERS` does nothing there.)

- **The bridge costs ~1 ms per request.** Same HTTP layer, same machine:
  178 µs without Python, 1.18 ms with. A 6.3x drop, against a Python
  callable that does essentially nothing. *(Since fixed — see "What the
  bridge is actually doing" below: 12,421 → 28,911 rps. The rows in this
  table are the pre-fix measurement that located the problem.)*
- **Granian on one worker beats m0serve on four** (124.6k vs 35.0k, 3.6x),
  and beats mojo-http serving *no Python at all* (1.6x). The Django-based
  1.4–2.0x understated the gap by roughly 5x.
- **So the headroom is in the bridge, not the concurrency model and not the
  HTTP layer.** mojo-http's HTTP layer is within 1.6x of Granian's
  *including* Granian's Python work; its bridge then gives all of that away.

**Is `apps/hello`'s 78.3k a ceiling, or just `-c16` divided by the
round-trip?** Worth asking, because 16 connections at 178 µs is ~90k, close
enough to the measured number that the two explanations are hard to tell
apart — and if it were the latter, the whole row would be a latency
measurement wearing a throughput label. Sweeping concurrency separates them:
a latency-bound number rises with connections, a saturated one does not.
`wrk -t4`, two rounds, same binary and box:

| connections | rps | p50 |
|------------:|----:|----:|
| 16  | 76,522 / 76,296 | 185 µs / 185 µs |
| 64  | 77,235 / 76,926 | 789 µs / 791 µs |
| 128 | 78,737 / 78,723 | 1.61 ms / 1.61 ms |
| 256 | 78,976 / 79,037 | 3.22 ms / 3.22 ms |

**It is a ceiling.** Throughput moves 3% across a 16x range of concurrency
while p50 tracks connection count almost exactly linearly (185 µs → 3.22 ms
is 17.4x for 16x the connections) — which is queueing being added and
nothing else, and is Little's Law with the service rate held constant. So
the layer-split row means what it says, and the Granian comparison built on
it stands. Recorded because the doubt was reasonable and only a measurement
could retire it.

### What the bridge is actually doing — measured, not assumed

Reading the code suggested the Python shim's environ parse. Splitting the
~1 ms by part (`scripts/bench_bridge_parts.mojo`, 20k iterations, a
twelve-header GET producing a 636-byte blob) put it somewhere else:

| part | before | after |
|------|-------:|------:|
| `serialize_request` (Mojo) | **48.10 µs** | **0.44 µs** |
| `buf_addr()` zero-arg call | 0.33 µs | 0.30 µs |
| copy blob into the shim's buffer | 0.91 µs | 0.90 µs |
| `handle()` — the call plus the whole Python shim | 12.31 µs | 12.35 µs |
| full round trip (copy + handle + body) | 14.59 µs | 14.46 µs |

**The Python shim was never the bottleneck.** A standalone microbenchmark
of `handle()` puts its blob parse at 11.5 µs of that 12.3 µs — real, but a
sixth of the total. The cost was `serialize_request`, in Mojo: `keys()`
allocated a String per header name, `get()` allocated another per value and
linear-scanned to find it, and `cgi_header_name` allocated three more
(`upper()`, `replace()`, and the `HTTP_`-prefixed result). Seventy-odd
String allocations per request to move twelve headers.

The fix allocates nothing: walk `count()` with `Headers`' own
`name_span`/`value_span` (made public for this — see NOTICE) and write the
CGI name's bytes straight into the blob, uppercasing and mapping `-` to `_`
in place. The reserve is computed from the same spans, so filling the blob
never reallocates. The rule now exists in two forms — `cgi_header_name`
states it readably, `_append_cgi_name` writes it — so `test_environ.mojo`
asserts the two agree on every shape the rule distinguishes.

**End to end, same interpreter, two rounds** (`m0serve` + `apps/wsgi_bare`,
one worker, browser-shaped request):

| | rps | p50 | p99 |
|---|---:|---:|---:|
| before | 12,289 · 12,280 | 1.21 ms | 2.47 ms |
| after | **28,911 · 28,915** | **508 µs** | **1.07 ms** |

**2.35x throughput, p50 and p99 both down ~57%.** `smoke-wsgi` (PEP 3333
conformance) green, and `smoke-django`'s RSS guard still reports 0 KB growth
over 10k requests — that guard is the right instrument for any change to
this boundary, for the reason the next paragraphs give.

Against Granian's 124.6k on the same row the gap is now 4.3x rather than
10x. The remaining bridge cost is ~14.5 µs, of which `handle()` is
five-sixths — so the Python-side environ build described next is now the
live target, which it was not before.

### The Python-side environ build

`bridge.mojo`'s shim rebuilds the WSGI environ **in pure Python on every
request**, by parsing the binary blob Mojo just wrote. For a twelve-header
browser request that is a `dict(_base)` copy, **28 `_read_str` calls** (each
a Python-level call, slice and decode), two `int.from_bytes`, and an
`io.BytesIO` — comfortably tens of microseconds. Granian builds the environ
in Rust and hands Python a finished dict.

The irony is that this is downstream of a *correct* decision. The blob
exists precisely because Mojo 1.0's `PythonObject` leaks a reference per
call argument, so the bridge cannot simply pass a dict (see Known issues in
ROADMAP.md). The leak workaround is what costs the throughput.

The way out is to build the environ dict in Mojo through the raw CPython C
API, which manages refcounts explicitly and is therefore not the leaking
path. `PyDict_New` and `PyDict_SetItem` are reachable today through
`Python().cpython()` — the same door `m0_wsgi.threaded` already uses for
`PyEval_SaveThread` — and were compile-checked against the pinned toolchain
before this was written down. `smoke-django`'s RSS guard is the instrument
that would prove such a change does not reintroduce the leak.

*(This section is the diagnosis. It was acted on — see "Built in Mojo through
the C API" below for what it cost and what it bought.)*

**Re-measured before acting on it**, because this exact recommendation was
wrong once already — it named the shim when the cost was `serialize_request`,
and only splitting the total by part caught that. The split reproduces:

| part | at the fix | re-measured |
|------|-----------:|------------:|
| `serialize_request` (Mojo) | 0.44 µs | 0.43 µs |
| `buf_addr()` zero-arg call | 0.30 µs | 0.29 µs |
| copy blob into the shim's buffer | 0.90 µs | 0.88 µs |
| `handle()` — the call plus the whole Python shim | 12.35 µs | 12.09 µs |
| full round trip | 14.46 µs | 14.23 µs |

`handle()` is **85% of what is left**, and the three Mojo-side parts together
are 1.6 µs. So the target above is the right one — which is a statement this
document has now earned rather than assumed.

### Built in Mojo through the C API: 14.9 µs → 3.5 µs

Done, and the split above is what says it worked rather than a guess that it
would. The environ dict is built in Mojo now: `PyDict_New` and
`PyDict_SetItem` for the dict, `PyUnicode_DecodeUTF8` for every key and
value, and `PyTuple_New`/`PyTuple_SetItem`/`PyObject_CallObject` to hand the
finished dict to the shim, which is left holding only the parts that have to
be Python — `start_response`, the application call, the joins, and `close()`.

The blob is gone entirely, and with it `serialize_request` and the 28
`_read_str` calls that parsed it back. **The request body is the one thing
that still crosses as bytes**, because Mojo 1.0 has no `PyBytes_*` binding
of any kind, so a `bytes` object cannot be built from Mojo at all: the body
goes through the same persistent bytearray as before and the shim makes the
`BytesIO`. A request with no body — every GET, and so every row in this
document — now skips that path completely: `buf_addr()` is never called and
nothing is copied.

Two constraints shaped it rather than merely being respected by it:

- **The environ could never have been passed as an argument.** That is the
  leak. `PyTuple_SetItem` steals a reference and `PyObject_CallObject` takes
  a tuple, so the C API hands the dict over with the refcount accounted for
  by hand. `PyDict_SetItem` does *not* steal, which is the mirror-image rule:
  every string built for it is `Py_DecRef`'d as soon as the dict has taken
  its own reference.
- **There is no `PyUnicode_DecodeLatin1` binding.** PEP 3333 tunnels raw
  request bytes through `str` as latin-1. Encoding those same codepoints as
  UTF-8 is a two-line transform — one byte below 0x80, two above — so the
  bytes are re-encoded here and decoded as UTF-8 there, producing exactly the
  `str` a latin-1 decode would. ASCII, which is nearly everything, is its own
  UTF-8 and needs no copy at all. `PATH_INFO` is why this is not academic: it
  arrives percent-*decoded*, so a non-ASCII path carries real high bytes.

Same instrument, 20k iterations, the same twelve-header GET, two runs:

| part | before | after |
|------|-------:|------:|
| `serialize_request` (Mojo) | 0.43 µs | — |
| `buf_addr()` zero-arg call | 0.30 µs | not called on a GET |
| copy blob into the shim's buffer | 0.88 µs | not called on a GET |
| `build_environ` — the whole dict, C API | — | **1.78 / 1.75 µs** |
| `handle()` / `run()` — the call plus the shim | 12.09 µs | **0.64 / 0.65 µs** |
| full round trip | 14.23 µs | **3.52 / 3.47 µs** |

**14.9 µs → 3.5 µs, 4.2x.** The Python shim, which this document twice had
to stop itself from blaming prematurely, really was the cost this time — and
it is now 0.65 µs.

**End to end, one worker on `apps/wsgi_bare`**, browser-shaped keep-alive
request, `wrk -t2 -c16 -d10s`, CPython 3.13, two rounds per server start.
The `before` run is bracketed by two separate `after` starts, so the
comparison is not an artifact of ordering or of one warm process:

| | rps | p50 | p99 |
|---|---:|---:|---:|
| before | 28,853 · 29,123 | 508 µs | 1.06 ms |
| after | **45,715 · 45,734** | **315 µs** | **681 µs** |
| after, again | 45,525 · 45,182 | 317 µs | 704 µs |

**1.57x throughput, p50 down 38%, p99 down 35%.** `smoke-django`'s RSS guard
— the instrument for any change to this boundary, because a missed
`Py_DecRef` is exactly the unbounded leak the design exists to avoid — still
reports **0 KB over 10k requests**.

**The Granian ratio is deliberately not restated here.** The layer-split
table above was measured on **3.14.7t** and this pair on **3.13**, so
dividing one by the other would be arithmetic across two interpreters. What
the numbers above support is the delta on one box with one interpreter and
one variable. Re-running `scripts/bench_layer_split.sh` on 3.14.7t is what
would move the 4.3x row, and until that happens the row stands as measured.

**What is left, and it is a different shape.** Of the 3.5 µs, 1.78 µs is the
environ build and 0.65 µs is the shim; the remaining **1.07 µs is getting the
response body back out**, in `body_bytes`. That is now 31% of the bridge,
against 5% of it before, purely because everything around it got smaller.

That description first read "a `len()`, a `body_addr()` crossing, and a
byte-at-a-time copy", which was a reading of the code rather than a
measurement — so it was measured, and it is **almost entirely one of those
three**:

| part | cost |
|------|-----:|
| `Int(len(body))` | 0.003 µs |
| `self._ns["body_addr"]` — the namespace lookup | 0.065 µs |
| **`self._ns["body_addr"]()` — lookup *and* call** | **1.095 µs** |
| `body_bytes` in total | 1.07 µs |

The `len()` is three nanoseconds and the byte copy of a 13-byte body is
noise. **The cost is the `body_addr()` call**, and specifically what that
function does — two `ctypes` object constructions per request:

    return ctypes.cast(ctypes.c_char_p(_body), ctypes.c_void_p).value or 0

which was the last per-request Python-level operation left in the bridge.

### The unbound C API is reachable, and that is the fix

The plan recorded here was to have the shim copy the response into a
persistent `bytearray` whose address Mojo caches — the request path's trick,
run backwards. That would have worked, at the cost of a second copy for large
bodies. It was not needed, because the premise underneath it was wrong.

`Python().cpython()` binds no `PyBytes_*` at all, and `external_call` cannot
reach them either — **libpython is not on the link line**. Mojo `dlopen`s it,
which is exactly why `CPython` is a struct of loaded function pointers rather
than a header. But that struct exposes its handle, and the stdlib's own

    ExternalFunction[name, type].load(cpy.lib.borrow())

is how it populates every one of its bindings. It works just as well for the
ones it omitted. So the whole CPython C API is available, not only the part
the stdlib chose to wrap — which is a considerably more useful fact than this
one optimisation.

`body_bytes` now runs no Python whatsoever: `PyObject_Length` for the length,
`PyBytes_AsString` for the address, one `memcpy` for the copy. The pointer is
resolved once at construction — loading is a `dlsym`, but the call it returns
is **1.0 ns**, against 1,095 ns for the `ctypes` round trip. `PyBytes_AsString`
is stable-ABI and *checked*: it returns NULL and sets `TypeError` on a
non-`bytes`, where the `PyBytes_AS_STRING` macro would read the wrong offsets
— and a macro is not a symbol in any case.

| part | before | after |
|------|-------:|------:|
| response body out | 1.07 µs | **0.13 µs** |
| full round trip | 3.52 µs | **2.50 µs** |

**8.3x on that part, and the bridge is now 2.50 µs** — down from 3.52, and
from 14.9 before the environ builder. End to end, one worker on
`apps/wsgi_bare`, browser-shaped keep-alive request, the `before` bracketed by
two separate `after` server starts on the same box:

| | rps | p50 | p99 |
|---|---:|---:|---:|
| before | 45,891 · 45,441 | 315 µs | 690 µs |
| after | **48,852 · 48,871** | **295 µs** | **640 µs** |
| after, again | 48,516 · 48,872 | 295 µs | 691 µs |

**+6.7%**, and **1.69x cumulative** against the 28,853 rps this document
measured before any of the bridge work. `smoke-django`'s RSS guard still
reports **0 KB over 10k requests**: reading through a raw pointer takes no
reference, and the guard is what says it took none.

Recorded twice over, because both halves were instructive. The first
description named three costs and the answer was one of them — measure by
part. The fix that followed from that measurement was then also wrong, and
only checking whether the constraint was real rather than assumed found the
better one.

### The request body follows, and the blob design is fully retired

Once `PyBytes_FromStringAndSize` was known to be reachable, the request body
had no reason to keep crossing through the shim's bytearray: Mojo now builds
a real `bytes` straight from the request's own buffer (one copy, inside the
call) and hands it to the shim as the second stolen tuple slot next to the
environ. `io.BytesIO(bytes)` **shares** the immutable buffer until first
write — measured: `getsizeof` of a BytesIO built over 256 bytes is 289 — so
`wsgi.input` costs no second copy where the old
`io.BytesIO(memoryview(_buf)[8:8+n])` always copied. An app that *writes* to
`wsgi.input` triggers CPython's unshare, checked explicitly.

Gone with it: the 64 KB transfer bytearray, the `buf_addr()` address call,
the grow protocol and its size-through-the-old-buffer handshake, and
`ctypes` itself — the shim now imports nothing but `io`. Every request costs
exactly one call into Python: the `PyObject_CallObject` that runs
`run(environ, body)`.

Same instrument, 1 KB POST alongside the usual GET, two runs each:

| part | before | after |
|------|-------:|------:|
| `run()` GET, no body | 2.47 µs | 2.37 / 2.46 µs |
| `run()` POST, 1 KB body | 4.04 / 4.08 µs | **2.46 / 2.52 µs** |
| derived: 1 KB body staging | 1.57 / 1.61 µs | **0.086 / 0.063 µs** |

**Staging a 1 KB body went from 1.6 µs to 0.07 µs — ~23x** — and a POST now
costs what a GET costs. End to end, one worker, `apps/wsgi_bare`'s
`/input/read` (which `read()`s the whole body and answers `len= sum=`, so a
truncated or corrupted body changes the response), 1 KB POST over keep-alive,
`wrk -t2 -c16 -d10s`:

| | rps | p50 | p99 |
|---|---:|---:|---:|
| before | 42,308 · 41,942 | 344 µs | 749 µs |
| after | **47,516 · 47,284** | **303 µs** | 675 µs |
| after, again | 47,294 · 47,137 | 303 µs | — |

**+12.4% on POSTs, GETs unchanged** (48.6k · 48.9k, the same as before this
change). Byte-exactness is pinned at eleven sizes straddling the old 64 KB
grow threshold, in JIT and in a built binary, plus alternating sizes on one
bridge — the shape that would catch a stale shared buffer. `smoke-django`'s
RSS guard still reports **0 KB over 10k requests**, which is what says the
stolen-reference accounting is right.

### build_environ, split — and the fix the measurement killed

With both bodies retired, `build_environ` was 71% of the bridge (1.78 µs of
2.50), so it was split into constituents before anything was designed
against it. 50k iterations each, request-realistic counts:

| operation | cost |
|-----------|-----:|
| `PyDict_New` + free | 11 ns |
| base replay: 10 × `PyDict_SetItem`, cached objects | 214 ns |
| **`PyDict_Copy` of the same 10-entry base** | **58 ns** |
| 12 header-name decodes (`PyUnicode_DecodeUTF8` + free) | 180 ns |
| 12 header-value decodes | 154 ns |
| 12 × `PyDict_SetItem` into a fresh dict | 260 ns |
| 12 × byte-compare, all hits — an intern cache's lookup | **245 ns** |
| `Python().cpython()` re-acquisition | 2.3 ns |

**The obvious fix was a net loss, and only the split caught it.** The plan
was to intern the recurring header names and values — `HTTP_USER_AGENT` and
its value are byte-identical on every request of a connection — but the
byte-comparisons an intern cache pays on its *hit* path (245 ns) cost more
than the decodes it would skip (180 ns). Short-ASCII `DecodeUTF8` is 15 ns;
there is nothing to save. The cache was never built.

What survived the measurement: the base entries now live in a **finished
template dict** and each request starts from `PyDict_Copy` of it — one C
call instead of ten hash-and-stores — and `Python().cpython()` is acquired
once per request instead of sixteen times (2.3 ns each; real, just small).
The template is copy-isolated by construction: an app that vandalizes its
environ — overwrites `SERVER_NAME`, deletes `wsgi.version` — mutates its own
copy, and a probe drives ten vandal/inspect cycles plus a second `set_base`
to prove the template stays pristine and replaceable.

| part | before | after |
|------|-------:|------:|
| `build_environ` | 1.78 µs | **1.57 / 1.55 µs** |
| full GET round trip | 2.57 µs | **2.37 / 2.33 µs** |

End to end this is **within wrk's noise** (~48k rps either side, p50
294 → 292 µs) — 0.2 µs against a ~20 µs total service time is ~1%, and the
part-split is the instrument that can resolve it.

**And this is close to the floor.** What remains in `build_environ` is ~26
`PyDict_SetItem`s at ~21 ns that WSGI's environ shape mandates, sixteen
decodes of genuinely per-request text, and the copy — roughly 1.1 µs that
no cleverness at this boundary removes without changing what an environ
*is*. The bridge work is at diminishing returns; the next real move is the
Granian re-measurement on 3.14.7t, which the layer-split row has been owed
since three bridge improvements ago.

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
run. `granian` is absent because it is not in this repo's lock file and a
swapped venv therefore has none — its flat row is recorded in the section
above and was the reference the design copied, not part of this gate.

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
- **It costs throughput, and the cost is not the same in both modes.** At
  slow=0, two-round means: prefork gives up **7.3%** (34.9k → 32.3k rps) and
  threads **21.3%** (32.7k → 25.7k). The extra hop is one datagram each way per
  request, and that is the 7% both modes pay. The remaining 14% is *not*
  explained by thread count: `--threads 4 --blocking-threads 4` is four loops
  plus sixteen handler threads, and `--workers 4 --blocking-threads 4` is four
  processes of five — **twenty threads either way**, on four performance
  cores. What differs is four independent interpreters against one shared
  between twenty threads. See "Sizing the pool" below, which also says why no
  startup warning fires on a large pool.
- **So the flag is a trade, and that is why it is off by default**: a few
  percent of peak throughput, and a p99 that stops depending on what other
  requests are doing. An application whose views are uniformly fast should
  not take it; one with a single slow report, an upstream call or a large
  query should.

### Sizing the pool

The measurement above says what oversubscription costs but not what to
choose, so: **size `B` to the number of requests you expect to be *waiting*
at once, not to the core count.**

The arithmetic first, because it is easy to get wrong in the other
direction. Both modes create the same total:

    --workers W --blocking-threads B   →  W × (B + 1) threads, across W processes
    --threads T --blocking-threads B   →  T × (B + 1) threads, in one process

`+ 1` because each loop keeps its own acceptor thread. `--workers 4
--blocking-threads 4` and `--threads 4 --blocking-threads 4` are both twenty
threads. That matters because it means **thread count alone does not explain
the 7.3% against 21.3%** — the two rows above have identical thread counts.
What differs is that four processes are four independent interpreters, and
four loops are twenty threads contending on one interpreter's shared
structures. Recorded as the honest limit of this measurement: the mechanism
is inferred, not measured, and separating them would need a profile rather
than a throughput number.

The rule that follows from what the pool is *for*:

- **A thread waiting on a database, an upstream call or a `sleep` is not
  runnable**, and costs no core. That is the entire workload the pool exists
  to isolate. So `B` tracks *concurrent waits*, and a pool much larger than
  the core count is correct when views genuinely wait — which is why
  gunicorn's `--threads` is routinely 4–8 per worker against far fewer cores.
- **A thread running Python bytecode is runnable**, and there the cost above
  is real. The benchmark's fast view does no waiting at all, which is exactly
  why it shows the penalty so cleanly — it is the worst case for the flag,
  not the typical one.
- **A starting point**, when the mix is unknown: `B = 4` with `W` or `T` at
  the core count, then raise `B` only while p99 under mixed load keeps
  improving. Past that, more threads buy queueing rather than concurrency.
- **Prefer `--workers W --blocking-threads B` to `--threads T
  --blocking-threads B`** at the same total, on this evidence: same thread
  count, a third of the throughput cost, and it needs no free-threaded
  interpreter.

No startup warning is emitted for a large `T × (B + 1)`. A pool sized for
waiting views is *supposed* to exceed the core count, so the server cannot
tell an oversubscribed configuration from a correctly-sized one without
knowing what the views do.

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

## Reproducing

For the threads-vs-prefork row: `uv run poe py314t-try`, export
`MOJO_PYTHON_LIBRARY` (from `sysconfig`'s `LIBDIR`/`INSTSONAME`) and
`PYTHON_GIL=0`, `uv pip install --python .venv/bin/python gunicorn`,
`.venv/bin/poe build-serve` (a Mojo binary carries an `@rpath` into the venv
it was built in, so rebuild inside the swap), then
`scripts/bench_wsgi_modes.sh`; `uv run poe py314t-restore` afterwards. Bare
`.venv/bin/poe`, never `uv run`, while swapped — a `uv run` re-syncs the venv
back to 3.13 mid-run. **Rebuild `bin/m0serve` again after restoring**: the
binary left behind by the swap has an `@rpath` into a venv that no longer
exists and aborts on start.

For the layer split and the mixed-workload row, the same setup plus
`granian`, then `scripts/bench_layer_split.sh` or
`scripts/bench_mixed_workload.sh`. The layer split also needs `apps/hello`
built inside the swap (`mojo build ... apps/hello/server.mojo`), for the
same `@rpath` reason as `bin/m0serve`.

`bench_mixed_workload.sh` is now a **regression gate** rather than a
decision: its `+bt=N` rows must stay flat under slow load, and its rows
without the flag must keep showing the ~120x degradation. A control that
stops failing has stopped measuring anything, which is why both halves are
in one script and one run. `granian` is not in this repo's lock file, so a
swapped venv has none and its row is skipped; that row is a reference, not
the gate.

**Do not run any `uv run` command while swapped** — not even `uv run mojo
run` on an unrelated scratch file. It re-syncs the venv back to 3.13
underneath the benchmark, and the symptom is not an error message: the Mojo
binaries start aborting on a stale `@rpath` and `.venv/bin/granian`
disappears, so rows silently go missing rather than failing loudly. Bare
`.venv/bin/poe` and `.venv/bin/mojo` are safe; `uv run` is not.

For the tail row, the same setup plus `granian`, then
`scripts/bench_wsgi_tail_ka.sh`. Use that one, not `bench_wsgi_tail.sh`, for
any keep-alive question: the close-per-request runs in the latter exhaust
the ephemeral port range and poison every row after the first. Never edit
either script while it is running — bash reads a script by byte offset, and
a mid-run edit shifts it (that is what produced the stray syntax error at
the end of the recorded run, after all its rows had been written).

No poe task, because gunicorn is deliberately not a dependency of this repo.
The shape of a run:

```bash
uv run poe build-serve               # -> bin/m0serve
source .venv/bin/activate            # the embedded CPython must see Django
bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers 2 &

# A browser-shaped request; wrk's default sends only Host, which understates
# the header-handling cost by roughly 2.4x (see the header-count table above).
BROWSER=(-H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
         -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
         -H 'Accept-Language: en-US,en;q=0.9' -H 'Accept-Encoding: gzip, deflate, br'
         -H 'Cache-Control: max-age=0' -H 'Upgrade-Insecure-Requests: 1'
         -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document'
         -H 'Referer: http://127.0.0.1:8080/')

wrk -t2 -c16 -d10s --latency "${BROWSER[@]}" http://127.0.0.1:8080/
wrk -t2 -c16 -d10s --latency "${BROWSER[@]}" -H 'Connection: close' http://127.0.0.1:8080/

cd apps/django_wsgi && uv run --with gunicorn python -m gunicorn \
  djangoproj.wsgi:application -w 2 -b 127.0.0.1:8080 --log-level warning
```

To reproduce a *before/after* claim rather than an absolute, build both
binaries first and alternate them within one session — start A, measure,
kill, start B, measure, kill, repeat. Given the drift above, three or more
alternating rounds are the minimum worth quoting, and the ratio is the
result; the absolutes are not.

When killing the mojo server, kill the workers too — they are forks of the
supervisor, and their pids are in its startup output. `M0_ACCESS_LOG=true`
logs per-request server-side duration, which is how in-loop time gets
separated from accept-queue wait when a latency number needs explaining.
