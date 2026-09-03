# Mojo language capabilities, surveyed 2026-08-28

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

A pass over what the tree uses of the language, prompted by "are we fully
tapping Mojo?". The short answer is yes wherever it was measured to pay —
SoA span-based headers (+72%, the largest single win here), SIMD parsing, an
allocation-free router, 14 `comptime if` platform specialisations, the raw
C API at the Python boundary, `ExecutorPort` at ~70 ns. What was missing was
expressiveness, and `HTTPService`'s default bodies and `m0_http.reply` are
that gap closed. The rest is recorded here.

- **More SIMD in the request path.** Was refused by our own profile — 31 of
  35 stack samples in `__libc_send` (SERVER_PERFORMANCE.md) — and the
  instrument that entry asked for, once built, disagreed with the profile.
  `scripts/bench_http_parts.mojo` (2026-08-28) put `parse_request_headers`
  at **two thirds** of the user-space request: the profile's verdict was
  drawn at 50k rps and the server now does 116k, so a cost that was
  invisible in loopback noise is a quarter of every request. The
  span-based `HTTPHeader` that fell out of it took the parse from 2.52 to
  2.05 µs (−12% on the whole user-space request). What remained — the
  byte-at-a-time scanner tail below 64 bytes, twelve `set_bytes` appends,
  three linear RFC checks — was recorded as the next lever, and **taken
  2026-08-29: the parse is 0.86 µs and the user-space request 1.97 µs
  (−40%)**. The instrument, split one level further, said the lever was
  not where the entry above put it: half the parse was the wrapper's blob
  build, 0.3 µs was the offsets array's fill (66 ns measured alone, where
  the compiler elides it), and the SIMD scanners were spending their time
  in a scalar walk over the lanes of a chunk they had already matched —
  9.4 ns per chunk against 0.8 for a `select` of `iota`. The story is in
  SERVER_PERFORMANCE.md; the lesson for this list is that a part measured
  in isolation can be a fifth of its cost in context, and the instrument
  has to be split until the number stops moving. What remains is 0.86 µs
  against a 5.3 µs syscall floor no parser can touch; the per-byte token
  check was measured against a bit table and is a wash. `escape_html`,
  `chunked.mojo`'s copy loops and `Headers._name_matches` are still
  scalar and, per the same instrument's lookup rows (30–70 ns each), still
  not worth it.
- **`simdwidthof` / SIMD width portability.** Every one of the 18 SIMD sites
  hardcodes 64/16/8/4 lanes and `simdwidthof` appears nowhere. Moot for the
  shipped artifact regardless: `build-serve` pins `--target-cpu apple-m1`,
  so the wheel already forfeits newer width. Related to the desktop-Mac open
  question below, not separable from it.
- **GPU / MAX.** Established and declined. Mojo 1.0 moved the accelerator
  APIs out of the stdlib into the `max` package, which this repo does not
  pin — `from gpu.host import DeviceContext` fails here, and that is now a
  fact about the language's packaging rather than about our install. Linking
  MAX into an HTTP server to serve a request is a different product; the
  open question below is where that belongs if it belongs anywhere.
- **Native async Mojo handlers (an `async def` handler on a Mojo reactor).**
  Distinct from the coroutine entry above, and refused for a different
  reason than "the language cannot". It can, partly — measured 2026-08-28,
  not assumed:

  `std.runtime.asyncrt` **exists on the pinned 1.0.0** and exports
  `TaskGroup`, `create_task`, `Task`, `TaskGroupContext` and
  `parallelism_level` (4 on this M4). It works, and it is genuinely
  multi-threaded: four CPU-bound `async def`s in a `TaskGroup` ran **3.6x**
  faster than the same work serially. `create_task(coro).wait()` from a sync
  `main` is fine — but `Task(coro).wait()`, the spelling recorded elsewhere
  as segfaulting, still crashes, so the constructor is the trap, not
  async-from-sync. The module also ships `RaisingTask` /
  `create_raising_task`, which is the pair that would matter here:
  `HTTPService.func` is the one method that `raises`, so a handler task
  cannot use plain `create_task`.

  **What it is not is a reactor.** There is no awaitable I/O: no `sleep`, no
  `block_on`, nothing that takes a file descriptor. A blocking syscall inside
  a task occupies a runtime worker. Sixteen tasks each blocking 200 ms took
  **816 ms**, against 800 ms predicted for a 4-worker pool and 200 ms for a
  reactor — so this is a work-stealing compute pool, and connection
  concurrency is exactly the thing it cannot give us. Anything reactor-shaped
  is still ours to write and maintain, for handlers that today block a pool
  thread perfectly well. Gate it on a real application that needs it.

  The positive half is worth keeping in view: `asyncrt` is the right tool for
  **CPU fan-out inside one handler** — a Mojo handler doing real computation
  can parallelise it with no pool, no threads of our own and no `--blocking-
  threads`. That also sharpens what the handler pool is *for*: blocking, not
  computing. Which is why the pool spike's kill criterion measures a handler
  that blocks.
- **`std.base64` / `std.hashlib` for the WebSocket handshake.**
  `websocket.mojo:24-27` already argues the hand-rolled SHA-1 and base64:
  one hash of one short string per connection open, and nothing else in the
  repo needs either. Recorded so the argument is not re-run.
