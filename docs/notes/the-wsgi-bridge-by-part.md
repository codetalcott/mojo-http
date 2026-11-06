# The WSGI bridge, measured part by part — 2026-08-23

> A design note from the engineering record, moved out of
> [WSGI_PERFORMANCE.md](../WSGI_PERFORMANCE.md) on 2026-11-06 and kept as
> written. The page itself now holds the current tables; the runs that led
> to them live here.

This note records where the Granian gap on bare WSGI lived: the layer
split of 2026-08-23, the bridge's cost part by part through the work that
moved the environ, the request body and the response head into Mojo by
2026-09-04, and the CPU-normalised re-measurement of 2026-08-26 that
inverted the conclusion twice. Every figure is the record of its date.

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

| row | what it adds | 2026-08-23 | **re-measured 2026-08-24** |
|-----|--------------|-----------:|---------------------------:|
| `apps/hello` | mojo-http HTTP layer, **zero Python** | 78,290 | **77,484** · 180 µs |
| `m0serve` + bare, 1 worker | …plus the WSGI bridge | 12,421 | **48,921** · 292 µs |
| `granian` + bare, 1 worker | Granian's HTTP layer + its PyO3 bridge | 124,642 | **122,314** · 111 µs |
| `m0serve` + bare, 4 workers | | 34,995 | **101,892** · 120 µs |
| `granian` + bare, 4 workers | | 99,187 | **98,489** · 131 µs |

(`apps/hello` has no `WorkerSupervisor`, so it is single-process by
construction and `M0_WORKERS` does nothing there.)

**The re-measurement is trustworthy because the controls held.** Nothing in
this repo touched the HTTP layer or Granian, and all three rows that should
not have moved reproduced within 2% — `apps/hello` 0.99x, Granian 0.98x at
one worker and 0.99x at four — across a five-week gap and a Granian bump
from 2.8.1 to 2.8.2. The two rows that *did* move are exactly the two the
bridge work touched: **m0serve 3.94x at one worker and 2.91x at four.** A
run where the controls had drifted would not support any of what follows.

- **At four workers, m0serve is now ahead of Granian** — 101,892 against
  98,489, a 1.035x lead where Granian was 2.83x ahead. Read honestly, that
  is two effects: m0serve gained 2.91x, *and* Granian gives up 19% going
  from one worker to four (122.3k → 98.5k) on a box with four performance
  cores, which is oversubscription rather than anything mojo-http did.
  m0serve scales 2.08x over the same step.
- **At one worker the gap is 2.50x**, down from 4.31x against the
  post-#76 number. This is the row that still favours Granian, and it is no
  longer mainly the bridge.
- **The remaining gap is now half HTTP layer, half bridge — and they are
  almost exactly equal.** `apps/hello` → m0serve w1 is 1.58x (the bridge);
  Granian w1 → `apps/hello` is also 1.58x (the HTTP layer, since Granian
  serves *with* its Python work faster than mojo-http serves with none).
  1.58 × 1.58 = 2.50, which is the whole w1 gap and nothing else.

**That last line is the strategic result.** When this section was written the
bridge was 6.30x of the stack and the HTTP layer 1.59x, so the bridge was the
only sane target — which is what the five changes since then acted on, taking
it to 1.58x. There is now no lopsided target left: further bridge work can
recover at most 1.58x, and the HTTP layer is worth exactly as much. The
original conclusion — *"the headroom is in the bridge, not the HTTP layer"* —
was right when measured and is now spent.

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
~1 ms by part (`scripts/probes/bench_bridge_parts.mojo`, 20k iterations, a
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
live target, which it was not before. *(The 4.3x has since been
re-measured at **2.50x** — see the re-measured column in the layer-split
table above.)*

### The Python-side environ build

`bridge.mojo`'s shim rebuilds the WSGI environ **in pure Python on every
request**, by parsing the binary blob Mojo just wrote. For a twelve-header
browser request that is a `dict(_base)` copy, **28 `_read_str` calls** (each
a Python-level call, slice and decode), two `int.from_bytes`, and an
`io.BytesIO` — comfortably tens of microseconds. Granian builds the environ
in Rust and hands Python a finished dict.

The irony is that this is downstream of a *correct* decision. The blob
existed precisely because Mojo 1.0's `PythonObject` leaked a reference per
call argument, so the bridge could not simply pass a dict. (The leak was
fixed in Mojo 1.1.0 and the pin moved on 2026-09-18, after this was
measured; the C API path stayed, being the faster one.) The leak workaround
is what costs the throughput here.

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
that still crosses as bytes**, because `std.python` binds no `PyBytes_*` of any
kind — re-checked on the 1.1.0 pin — so a `bytes` object cannot be built
through it at all: the body
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

**The Granian ratio was deliberately not restated from this pair.** The
layer-split table was measured on **3.14.7t** and this pair on **3.13**, so
dividing one by the other would have been arithmetic across two
interpreters. *(`scripts/bench_layer_split.sh` has since been re-run on
3.14.7t — see the re-measured column above. It puts m0serve at one worker at
48,921 rps, against the 48,852 measured here on 3.13: the two interpreters
agree to within 0.2% on this row, which is why the cross-interpreter
division would in fact have been close. Refusing to do it was still right —
that agreement was not knowable in advance, and is itself now a
measurement.)*

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

### The response half, which no split had ever covered

Every split in this document measured the *request* side. `serve()` is
`run()` plus `build_response`, and `bench_bridge_parts.mojo` stopped after
`run()` — so after five rounds of optimising the request path, the response
path had never been priced at all.

It was **ten times larger than the thing being optimised.** With Django's
default six response headers:

| | before | after |
|---|---:|---:|
| request side (`run()`, GET) | 2.18 µs | 2.16 µs |
| **response side (`build_response`, 6 headers)** | **22.97 µs** | **3.30 µs** |
| `serve()` = both | 25.51 µs | **5.65 µs** |
| per response header | 3.72 µs | **0.29 µs** |

**And the cause was not what the arithmetic suggested.** The gap was found by
subtracting the microbenchmark from the end-to-end number — `apps/hello` at
12.91 µs/request against `m0serve` at 20.44, a 7.53 µs WSGI path where the
bench only accounted for 2.36 — and the obvious suspect was the one thing
`build_response` does that the request side had already purged: reading the
app's headers through `PythonObject` iteration, two `String(py=…)` per pair.

Split by part, that idiom is **1.27 µs — 5% of it**. The cost was
`name.lower()`, a Mojo-side call, at **19.36 µs per response**: a fresh
Unicode-lowercased copy of every header name, allocated for the sole purpose
of testing one constant.

    if name.lower() == HeaderKey.SET_COOKIE:      # 3.2 µs per header
    if name_is(name.as_bytes(), HeaderKey.SET_COOKIE):   # 2.6 ns per header

`name_is` was already in the repo, already used for the identical Set-Cookie
dispatch on the request side, and its own docstring names the mistake:
*"lets the parser dispatch on field names without calling `.lower()`, which
allocated a copy of every header name on every request."* The request parser
learned this; the response builder never did. The fix is that one call.

End to end on `apps/wsgi_bare` — which returns **one** header, the least
favourable case for this change — the `before` bracketed by two `after`
runs:

| | rps | p50 |
|---|---:|---:|
| before | 49,517 · 49,436 | 291 µs |
| after | **56,896 · 56,591** | **252 µs** |
| after, again | 56,541 · 56,429 | 253 µs |

**+14.5%, p50 −13%**, on the shape that benefits least; a six-header Django
response saves 19.7 µs rather than 2.5.

`name_is` and `ascii_lower_byte` now have direct unit tests
(`test_headers.mojo`) — they had none, and they are now the whole of header
case folding in *both* directions. The boundary test was checked by widening
the `A`–`Z` range by one byte, which makes it fail.

**What was left of `build_response`, and what taking it bought
(2026-09-04).** The `PythonObject` read was 1.27 µs (38% of the remaining
3.30) and `Headers()` plus six stores another 1.39; the first belonged in
`bridge.mojo` rather than `response.mojo` if the bridge was to stay the
one file that touches the interpreter, so it waited for
a design decision. The decision is `PyBridge.read_head`: the list walked
through `PyObject_Length`, `PyList_GetItem` and `PyTuple_GetItem`
(borrowed references, never DecRef'd), each `str` read through
`PyUnicode_AsUTF8AndSize` — CPython's cached UTF-8 on the object, the same
text `String(py=…)` produced, so the wire is unchanged — and the `Headers`
blob sized once from a first pass over the same pointers. Re-measured on
the same instrument before and after, on a newer box than the table above
(Apple M4, CPython 3.13.6), the six-header response went **2.08 → 0.96 µs**
and `serve()` **3.86 → 2.61 µs**; per header 0.23 → 0.08. The same read
serves the ASGI executor's head, which now crosses as the application
sent it — an `int` status and `(bytes, bytes)` pairs — and the rest of
that branch (the scope built in Mojo, one request object instead of three
closures) is [its design note](executor-python-objects.md): the
executor's Python-side cost per request 5.74 → 3.82 µs, +7–10 % rps at 16
connections and +6–7 % at 256 on fewer cores.

### Re-measured 2026-08-26: CPU-normalized, and the conclusion inverts twice

Two findings from re-running the split on a genuine 3.14.7t, and they
retire this section's "dead even — no lopsided target left" conclusion.

**First: the comparator was never one core.** Granian's `--workers 1`
worker was measured at ~1.6 cores across 6 threads (its Rust runtime's I/O
threads, beyond `--blocking-threads 1`), while `apps/hello` and `m0serve`
hold one serving thread at ~100%. Every raw-rps ratio in the tables above
silently compared ~1.6 cores against one. The rows below carry a measured
`cores` column so that cannot happen again — sampled from the pids on the
listen socket, because Granian's launcher idles at 0% while a spawned
worker serves.

**Second: after CPU normalization and the profile-ranked allocation pass**
(Headers' packed index, move-not-copy response ctors, no `String(int)` in
the per-request path — see NOTICE), the hello row's per-core rate now meets
or exceeds Granian's end-to-end rate, and what remains of the gap is the
bridge. The 2026-08-24 numbers above are records of what was measured, not
descriptions of the present.

**Corrected 2026-08-26.** This paragraph used to state the result as a
decomposition — "roughly 1.0x HTTP layer × ~1.35x bridge" — and that does
not reconcile with the artifact below it. The measured per-core gap is
**1.17x** (100,009 / 85,185, the 2026-08-26 artifact); a 1.35x bridge term would require an HTTP
layer term of 0.89x, i.e. this server's HTTP layer *slower* than Granian's,
which the same sentence denies. The error is structural rather than
arithmetic: **a two-sided decomposition needs both sides measured**, and
there is no Granian-without-Python row in this run to divide by. What the
artifact does support:

- `apps/hello`, no Python in the path: **115,901 rps/core**
- m0serve + bare WSGI: **85,185 rps/core** — so *this server's* bridge
  cost **1.36x**
- Granian + bare WSGI: **100,009 rps/core** — so the net was **0.85x**

Granian's own bridge cost is unknown here, and a per-side split needs a
`granian`-equivalent of the hello row. The figure had been propagated into
README.md and docs/BENCHMARKS.md before it was checked, which is what
motivated holding the prose to the artifacts: the generated tables were
never wrong, and the sentences around them were answerable to nothing.
The first mechanism was a checker holding hand-written patterns against
the sentences (`check_bench_prose`); the current one generates the
numbers in place — the `num:` spans `render_bench_docs.py` writes and
`--check` refuses stale.

**Which per-core rows to trust, and why (2026-08-25).** The cores column's
first artifact showed m0serve w4 at ~51k rps/core against ~84k at w1, which
reads like a prefork scaling defect. Chased down, it is the benchmark
box's efficiency cores
([BENCHMARKS.md](../BENCHMARKS.md#how-to-read-this-page) has their rate and
which rows they leave comparable). At w4 the server (~3.2 cores) plus wrk
(~2.3) demand ~5.5 cores, so worker CPU-seconds spill onto E-cores and the
blended rps/core craters while total rps plateaus at the box's ~165–170k
co-located ceiling; raising offered load (c16→c128) moves neither number,
which rules out under-driving. The clean scaling data: **w2 runs at 96%
of w1's per-core rate** (83.2k vs 86.9k, server+wrk ≤ 4 P-cores), and
w3's 60k/core sits exactly on the spillover curve (2.76 + ~2 > 4). The
same mechanism retro-explains Granian's recorded "19% loss from w1 to
w4": that was never purely its own oversubscription either.
