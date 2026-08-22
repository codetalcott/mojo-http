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
