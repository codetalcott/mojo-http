# WSGI performance: mojo-http vs gunicorn

First measured 2026-08-16, once the prefork concurrency story existed. Before
that, `HTTPService.func` served one request at a time per process and any
throughput claim would have been noise about the wrong bottleneck. Re-measured
the same day after two serving changes this document motivated: the shared
pre-fork listener, and the move from the blocking accept loop to the
non-blocking event loop.

## Setup

Same Django project (`apps/django_wsgi/djangoproj`, `DEBUG = False`, no
middleware), same worker counts, same machine, same load generator.

- 4-core Linux container, everything (server + load) on one box
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
actually do. gunicorn's numbers were the same in both client modes, as
expected — its server-side close decides.

## Requests per second

| Workers | mojo-http (keep-alive) | mojo-http (close) | gunicorn (best of both modes) |
|--------:|-----------------------:|------------------:|------------------------------:|
| 1       | 6,720                  | 5,238             | 4,123                          |
| 2       | 12,819                 | 10,816            | 8,019                          |
| 4       | 21,528                 | 14,303            | 9,655                          |

Keep-alive — the mode a fronting proxy uses — serves ~1.6x gunicorn's
throughput at 1–2 workers and ~2.2x at 4. The 4-worker rows carry a caveat
for both servers: 4 workers plus 2 wrk threads oversubscribe 4 cores, so the
load generator competes with the servers it is measuring.

## Latency

Keep-alive is clean at every worker count: p50 in the hundreds of
microseconds, p99 of 5–8 ms. It was not always — see the history below,
which is why the numbers in this section exist at all.

`Connection: close` now carries the tail instead: medians stay low
(p50 2.9 ms at 1 worker, 1.4 ms at 2) but p99 reaches ~80–140 ms at 1 worker
(stable across repeated runs), ~21 ms at 2, ~5 ms at 4. That is an
accept-path cost of the event loop under high connection churn — thousands of
connect-request-close cycles per second against an edge-triggered listen
socket — and it fades as more workers drain the backlog. It is recorded as a
known issue in [ROADMAP.md](ROADMAP.md). A deployment behind a proxy holding
persistent upstream connections never sees this mode.

## History: why the event loop, with numbers

The first benchmarked configuration served each worker through the blocking
accept loop, which drains one accepted connection's keep-alive requests
exclusively — microsecond responses for that connection — until the idle
timeout or the `max_keepalive_requests` cap closes it, and only then accepts
the next waiting connection. Under 16 persistent connections that measured
p50 ~245 µs but p99 ~140 ms at 2 workers: fifteen connections queued while
one was being drained. `Connection: close` was clean on that loop (p99
2.1 ms at 2 workers), because every request re-entered the accept queue.

Moving the workers onto the non-blocking event loop — the same loop SSE
already requires — replaced connection-exclusive draining with multiplexing
between connections after every response. Keep-alive p99 fell from ~140 ms to
~5 ms at 2 workers and throughput rose at every worker count (keep-alive,
2 workers: 10,186 → 12,819 req/s; 4 workers: 16,373 → 21,528). The trade was
the close-mode tail described above. The view still runs synchronously on the
loop either way: a slow view stalls its whole process, and cross-request
concurrency remains `M0_WORKERS`'s job.

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
supervisor, and their pids are in its startup output.
