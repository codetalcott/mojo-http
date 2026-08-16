# WSGI performance: mojo-http vs gunicorn

First measured 2026-08-16, once the prefork concurrency story existed. Before
that, `HTTPService.func` served one request at a time per process and any
throughput claim would have been noise about the wrong bottleneck. Re-measured
the same day after each of three serving changes this document motivated: the
shared pre-fork listener, the move to the non-blocking event loop, and the
leak-free bridge.

## Setup

Same Django project (`apps/django_wsgi/djangoproj`, `DEBUG = False`, no
middleware), same worker counts, same machine, same load generator.

- 4-core Linux container, everything (server + load) on one box. The
  container is shared, so absolute numbers drift between sessions — each
  table row was measured in the same run as its gunicorn baseline.
- mojo-http: `apps/django_wsgi/server.mojo` compiled with `mojo build`
  (Mojo 1.0, the `uv.lock` pin), `M0_WORKERS=N`. Workers accept from one
  listener bound before the fork, the same model gunicorn uses — a busy
  worker simply doesn't accept, so connections land on free workers. (An
  earlier per-worker `SO_REUSEPORT` design measured ~20% lower at 4 workers,
  because REUSEPORT hashes connections to workers with no regard for load —
  and on macOS it does not distribute at all.) Each worker serves through the
  non-blocking event loop; the history below explains why.
- gunicorn 26.0.0, default sync workers, `-w N`, `--log-level warning`
- wrk: 2 threads, 16 connections, 10 s runs after a 3 s warm-up, against `/`
  (a plain-text Django view)

Two client modes, because the servers differ in one relevant way: gunicorn's
sync worker closes every connection (it does not implement keep-alive), while
mojo-http keeps connections alive. `Connection: close` is the apples-to-apples
comparison; keep-alive is what a reverse proxy in front of mojo-http would
actually do.

## Results

Requests per second, with wrk's p99 latency in parentheses:

| Workers | mojo-http (keep-alive) | mojo-http (close) | gunicorn (best of both modes) |
|--------:|-----------------------:|------------------:|------------------------------:|
| 1       | 5,865 (4.0 ms)         | 5,020 (5.9 ms)    | 3,883 (6.5 ms)                 |
| 2       | 11,443 (2.4 ms)        | 10,296 (2.3 ms)   | 7,723 (3.1 ms)                 |
| 4       | 19,596 (3.3 ms)        | 14,127 (4.7 ms)   | 9,613 (2.9 ms)                 |

~1.5x gunicorn's throughput at 1–2 workers and ~2x at 4, with p99 at or below
gunicorn's at 1–2 workers. The 4-worker rows carry a caveat for both servers:
4 workers plus 2 wrk threads oversubscribe 4 cores, so the load generator
competes with the servers it is measuring.

These numbers hold on a long-lived process — the table's close-mode runs were
taken *after* the keep-alive runs on the same workers, ~200k requests in.
That sentence is the point of the next section.

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
uv run mojo build -I packages/m0-core/ -I packages/m0-http/ -I packages/m0-wsgi/ \
  -I apps/ apps/django_wsgi/server.mojo -o /tmp/django_server
source .venv/bin/activate            # the embedded CPython must see Django
M0_WORKERS=2 /tmp/django_server &

wrk -t2 -c16 -d10s --latency http://127.0.0.1:8080/
wrk -t2 -c16 -d10s --latency -H 'Connection: close' http://127.0.0.1:8080/

cd apps/django_wsgi && uv run --with gunicorn python -m gunicorn \
  djangoproj.wsgi:application -w 2 -b 127.0.0.1:8080 --log-level warning
```

When killing the mojo server, kill the workers too — they are forks of the
supervisor, and their pids are in its startup output. `M0_ACCESS_LOG=true`
logs per-request server-side duration, which is how in-loop time gets
separated from accept-queue wait when a latency number needs explaining.
