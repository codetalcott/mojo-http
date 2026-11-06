# WSGI and ASGI performance

The WSGI path split by layer, threads against prefork on one
free-threaded interpreter, how to size the handler pool, two ASGI
framework rows, and how to reproduce each table. The head-to-head tables,
and how to read any table here, are on
[BENCHMARKS.md](BENCHMARKS.md#how-to-read-this-page). The runs that led
to these tables, from 2026-08-16 on, are dated notes:
[WSGI against gunicorn and the case for the pool](notes/wsgi-against-gunicorn-and-the-pool.md),
[the WSGI bridge, part by part](notes/the-wsgi-bridge-by-part.md) and
[the ASGI executor against uvicorn](notes/the-asgi-executor-against-uvicorn.md).

## The layer split

`scripts/bench_layer_split.sh` splits the WSGI stack into rows that differ
by one layer. `apps/hello` is mojo-http's HTTP layer with no Python in the
path. Every other row serves `apps/wsgi_bare`, a plain PEP 3333 callable
with no third-party imports, so the Python work is identical. Every root
returns 13 bytes of `text/plain`, and the script asserts byte parity
between m0serve and Granian before any timing.

From the newest artifact, the table below, with one worker in three
shapes: `apps/hello`
<!-- num:hello-rps-k@1 -->232.2<!-- /num -->k rps/core; the app inline on that loop <!-- num:m0-loop-rps-k@1 -->130.4<!-- /num -->k, the
bridge <!-- num:bridge-tax@2 -->1.78<!-- /num -->x of a faster HTTP layer; one handler thread, Granian's
shape, <!-- num:m0-wsgi-rps-k@1 -->111.7<!-- /num -->k against Granian's <!-- num:granian-rps-k@1 -->109.4<!-- /num -->k per core, the
net <!-- num:m0-per-granian@2 -->1.02<!-- /num -->x.

Absolute rows are not comparable across sessions
([BENCHMARKS.md](BENCHMARKS.md#how-to-read-this-page) says why).

<!-- generated: layer-split -- edit bench/results, not this table -->
Source: [`layer-split-20261106T212053Z.json`](../bench/results/layer-split-20261106T212053Z.json) — 2026-11-06T21:20:53+00:00, commit `5f069aec`.
Environment: Python 3.14.7; granian 2.8.7; Apple M4 (10 cores: 4P+6E); 16 GB; macOS 27.0.1 (26A434); AC Power; wrk -c16 -d10s, 3 rounds, medians.

| row | rps | cores | rps/core |
|-----|----:|------:|---------:|
| `apps/hello` — mojo-http HTTP layer, zero Python | 229,872 | 0.99 | 232,193 |
| `m0serve` + bare WSGI, 1 worker, app inline on the loop (no handler thread) | 129,065 | 0.99 | 130,369 |
| `m0serve` + bare WSGI, 1 worker, 1 handler thread | 197,699 | 1.77 | 111,694 |
| `granian` + bare WSGI, 1 worker, 1 blocking thread | 196,925 | 1.80 | 109,403 |
| `m0serve` + bare WSGI, zero-config (what `m0serve app.wsgi` runs) | 198,377 | 1.77 | 112,078 |
| `m0serve` + bare WSGI, 4 workers, 1 handler thread each | 155,321 | 4.60 | 33,765 |
| `granian` + bare WSGI, 4 workers, 1 blocking thread each | 153,491 | 4.05 | 37,899 |

Cores: sampled `%cpu` of the pids on the listen socket.
<!-- /generated: layer-split -->

The table between the markers is rendered from the newest artifact in
`bench/results/` by `uv run poe render-bench-docs`, and `poe check-docs`
(in CI) fails when it goes stale — the numbers cite a file rather than a
memory. The prose around it stays hand-written.

## Threads vs prefork, on one free-threaded interpreter

Measured 2026-08-22 on an M4 (4P+6E), **CPython 3.14.7t with the GIL off**
for all three servers — mojo-http's prefork mode, its threaded mode, and
gunicorn 26.1.0 — serving `apps/django_wsgi`'s hello route with a
twelve-header, browser-shaped request. ApacheBench this time (`ab -c16 -n20000`,
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

Threads serve at throughput parity with prefork, 0.92–1.05x across the
eight pairings and inside the round-to-round spread, because each thread
runs the same event loop and bridge a worker does. One process takes
about 60% of the memory of N, since the application is imported once.
Both modes serve about 3.3x gunicorn's rate at two loops and 3.5x at four
on the same interpreter; gunicorn's sync workers are processes and gain
nothing from free-threading.

## Sizing the pool

The pool is a zero-config WSGI application's default
([RUNNING.md](RUNNING.md#which-mode)), and `--blocking-threads 0` serves on
the loop alone. On the layer-split table above, the row with one handler
thread serves more than the inline one.

**Size `B` to the number of requests you expect to be *waiting* at once,
not to the core count.** Both modes create the same total:

    --workers W --blocking-threads B   →  W × (B + 1) threads, across W processes
    --threads T --blocking-threads B   →  T × (B + 1) threads, in one process

`+ 1` because each loop keeps its own acceptor thread. In the 2026-08
slow-view run, the pool cost prefork 7.3% of its throughput at slow=0 and
threads 21.3%. `--workers 4 --blocking-threads 4` and `--threads 4
--blocking-threads 4` are both twenty threads, so **thread count alone
does not explain the difference**. What differs is that four processes
are four independent interpreters, and four loops are twenty threads
contending on one interpreter's shared structures. The mechanism is
inferred; a profile would separate them.

The rule that follows from what the pool is *for*:

- A thread waiting on a database, an upstream call or a `sleep` is not
  runnable, and costs no core. That is the entire workload the pool exists
  to isolate. So `B` tracks *concurrent waits*, and a pool much larger than
  the core count is correct when views genuinely wait. gunicorn's
  `--threads` is routinely 4–8 per worker for the same reason.
- A thread running Python bytecode is runnable, and there oversubscription
  costs throughput. The benchmark's fast view does no waiting at all. That
  makes it the flag's worst case.
- Start from the zero-config pool ([RUNNING.md](RUNNING.md#which-mode)
  gives its size and what more threads overlap), and raise `B` while p99
  under mixed load improves. Past that, more threads only add queueing.
- Prefer `--workers W --blocking-threads B` to `--threads T
  --blocking-threads B` at the same total, on that run: the same
  thread count, a third of the throughput cost, and no free-threaded
  interpreter needed.

No startup warning is emitted for a large `T × (B + 1)`. A pool sized for
waiting views is *supposed* to exceed the core count, so the server cannot
tell an oversubscribed configuration from a correctly-sized one without
knowing what the views do.

## Framework rows

Measured 2026-08-27 with batching and the `run_forever` pump in, and not
re-recorded after the executor's later changes. The benchmark page's rows
are bare handlers on purpose — a view's own work hides the server — but a
developer's first comparison is their own framework, so
`scripts/bench_asgi_wrk.sh`, parametrized (`BENCH_NAME`,
`BENCH_APP_DIR`, `BENCH_M0_SPEC`, `BENCH_UV_SPEC`, `BENCH_PATH`), ran the
two ASGI framework apps in the tree at `/`: `wrk -t2 -c16 -d8s`, browser
headers, the executor on uvloop (the venv's), medians of three with the
uvicorn rows re-measured beside it, artifacts `asgi-wrk-fasthtml-*.json`
and `asgi-wrk-django-*.json`:

| app, `GET /` | m0serve executor | `uvicorn --loop asyncio` | ratio | uvicorn + uvloop | ratio |
|---|---:|---:|---:|---:|---:|
| FastHTML (`apps/fasthtml_demo`: a `Titled` page) | 3,977 rps @ 0.74 cores | 4,668 @ 1.02 | 0.85 | 5,264 @ 1.00 | 0.76 |
| Django ASGI (`apps/django_asgi`: a sync view through `ASGIHandler`) | 3,861 @ 0.73 | 3,261 @ 0.71 | **1.18** | 4,156 @ 0.72 | 0.93 |

Two readings. FastHTML — Starlette's stack, a few hundred microseconds of
Python per page — shows the bare app's shape at 16 connections: the
executor at 0.74 cores, idle between handoffs, 0.85x the asyncio
comparator and with the worse tail (p99 8.0 ms against 4.7). Django's
`ASGIHandler` runs a sync view through `sync_to_async`, a thread hop on
every request for every server — uvicorn sits at 0.71 cores there too —
and the executor is 1.18x uvicorn-asyncio and 0.93x uvloop, p99 5.2 ms
against 5.6 and 4.8. Both rows are a tenth of the bare app's rate: the
framework's own work dominates, which is the page's reason for keeping
bare handlers, and it makes the server gap a smaller share of any real
request than the bare rows make it look.

## Reproducing

Every run needs `bin/m0serve` from `poe build-serve`, `wrk`, and a machine
with nothing else busy: the shell benches refuse to start, and refuse to
begin a round, while any process outside their own tree is busy
(`scripts/bench_guard.py`). Granian is the `bench` dependency group
(`uv sync --group bench`), pinned exactly in `pyproject.toml` so a
comparator drift cannot move the rows silently; a `uv run` keeps it, a
bare `uv sync` removes it.

**The tables on [BENCHMARKS.md](BENCHMARKS.md)**, each one script, on the
default venv unless stated:

- Layer split: build `apps/hello` to `/tmp/bench_hello_server`
  (`uv run poe build-all`, then
  `uv run mojo build -I packages/m0-core -I packages/m0-http apps/hello/server.mojo -o /tmp/bench_hello_server`),
  then `scripts/bench_layer_split.sh`.
- ASGI throughput: `poe bench-asgi-wrk`. Fast-request tail under mixed
  load: `poe bench-asgi`. Both use the venv's uvicorn and uvloop, which the
  executor adopts because the script puts the venv first on `PATH`.
- Slow-view isolation, on free-threaded 3.14t because its `--threads` rows
  need that build: the swap below, then `scripts/bench_mixed_workload.sh`.
  It runs three rounds at least, and the renderer refuses fewer.

**The threads-vs-prefork table, and the 2026-08 tables in the notes**,
all under the swap:

- Threads vs prefork: `uv pip install --python .venv/bin/python gunicorn`,
  then `scripts/bench_wsgi_modes.sh`.
- The keep-alive tail: `scripts/bench_wsgi_tail_ka.sh`. Not
  `bench_wsgi_tail.sh` (removed on 2026-09-28, last in commit `a78f189`):
  its close-per-request runs exhaust the ephemeral port range and poison
  every row after the first.
- The 2026-08-18 gunicorn comparison has no script. Its shape, with a
  browser-shaped request:

```bash
uv run poe build-serve               # -> bin/m0serve
source .venv/bin/activate            # the embedded CPython must see Django
bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080 --workers 2 &

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

**The free-threaded swap.** `uv run poe py314t-try`, export
`MOJO_PYTHON_LIBRARY` (from `sysconfig`'s `LIBDIR`/`INSTSONAME`) and
`PYTHON_GIL=0`, install the locked Granian with
`uv export --frozen --only-group bench --no-hashes | uv pip install --python .venv/bin/python -r -`
(the swap syncs without the `bench` group), then `.venv/bin/poe build-serve`.
Afterwards `uv run poe py314t-restore`, then `poe build-serve` again. Two
rules, each of which has produced a confident wrong answer:

- While swapped, run bare `.venv/bin/poe` and `.venv/bin/mojo`, never
  `uv run` anything, not even on an unrelated scratch file. It re-syncs
  the venv to 3.13 underneath the benchmark, and the symptom is rows
  silently missing (a stale `@rpath` abort, `.venv/bin/granian` gone)
  rather than an error.
- A Mojo binary carries an `@rpath` into the venv it was built in, so
  `bin/m0serve` and `apps/hello` are rebuilt inside the swap and again
  after restoring; the binary the swap leaves behind aborts on start.
  The bench then reports `never healthy` on every row, and the server log
  names the library `dyld` could not load.

**For any run.** Never edit a bench script while it runs; bash reads a
script by byte offset. A close-per-request run leaves its connections in
`TIME_WAIT`, and macOS has 16,384 ephemeral ports: let them drain before
the next row, or that row measures port pressure. A row whose wrk output
has a `Socket errors` line is a failed measurement. On macOS `seq 1 0`
prints two lines, so check each baseline row against a known figure
before believing the rows compared with it. For a before/after claim,
build both binaries and alternate them within one session, three rounds
or more; the ratio is the result, the absolutes are not. When killing the mojo server, kill its
workers too, whose pids are in its startup output.

After recording, commit the artifact and run `uv run poe render-bench-docs`.
`render_bench_docs.py --check` refuses an artifact whose rows moved against
the comparators' since the previous one unless `--accept-drift` stamped it.
