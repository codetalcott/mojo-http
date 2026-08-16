# WSGI performance: mojo-http vs gunicorn

First measured 2026-08-16, once the prefork concurrency story existed. Before
that, `HTTPService.func` served one request at a time per process and any
throughput claim would have been noise about the wrong bottleneck.

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
  and on macOS it does not distribute at all.)
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

| Workers | mojo-http (close) | mojo-http (keep-alive) | gunicorn (best of both modes) |
|--------:|------------------:|-----------------------:|------------------------------:|
| 1       | 5,295             | 4,999                  | 3,832                          |
| 2       | 10,985            | 10,186                 | 7,433                          |
| 4       | 16,853            | 16,373                 | 9,850                          |

mojo-http serves ~1.4x gunicorn's throughput at 1–2 workers and ~1.7x at 4,
and scales close to linearly from 1 to 2 workers. The 4-worker rows carry a
caveat for both servers: 4 workers plus 2 wrk threads oversubscribe 4 cores,
so the load generator competes with the servers it is measuring.

## Latency, and the honest caveat

`Connection: close` latencies are clean on both servers — at 2 workers,
mojo-http p50 1.43 ms / p99 2.08 ms vs gunicorn p99 2.86 ms.

Keep-alive is where the honest reporting lives. mojo-http's p50 drops to
~245 µs — no accept, no TCP handshake — but the tail inverts: p99 reaches
~140 ms at 2 workers (p75 already ~65 ms). The distribution is bimodal, and
the mechanism is visible in `lightbug_http/server.mojo`: the blocking
`listen_and_serve` loop accepts a connection and serves *its* keep-alive
requests exclusively — microsecond responses for that connection — until the
idle timeout or the `max_keepalive_requests` cap closes it, and only then
accepts the next waiting connection. Fifteen other persistent connections
queue for hundreds of milliseconds. A connection-fairness cost of the blocking
accept loop, not a Django or bridge cost; the non-blocking event loop
multiplexes and should not have it. Listed in [ROADMAP.md](ROADMAP.md) as a
known issue. Until it is addressed, a latency-sensitive deployment should
terminate keep-alive at a proxy and speak `Connection: close` to mojo-http —
which still beats gunicorn on throughput.

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
