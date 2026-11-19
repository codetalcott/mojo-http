# Server performance

The Mojo server serving Mojo handlers: a compiled-in Mojo mount beside a
Python application, and workers against threads for a Mojo application
under the host. Both tables render from the newest artifact in
`bench/results/`.

A request's cost inside the server, part by part, comes from
`scripts/probes/bench_http_parts.mojo`: the header scan, the parse, the
request object, header lookups, routing and the response encode, each in
isolation (`uv run mojo run -I packages/m0-http -I packages/m0-core
scripts/probes/bench_http_parts.mojo`). A part measured alone can cost a
fraction of what it costs inside a request, so read it beside a `wrk`
run. The raw hot path's record, from the 2026-08-18 syscall budget to the
parse lever of 2026-08-29, is [a dated note](notes/the-raw-hot-path.md);
the loop's user space since then is
[notes/loop-user-space.md](notes/loop-user-space.md), the outbox sweep
[notes/outbox-sweep.md](notes/outbox-sweep.md) and the pump's pacing
[notes/pump-pacing.md](notes/pump-pacing.md).

## A Mojo mount beside Python

`--mount /native=mojo` serves a compiled-in Mojo handler on pool threads
that never touch the interpreter, beside a Python application in the same
process (SPEC M19). `uv run poe bench-mojo-mount` measures what that is worth
with one job on both mounts: a filtered top-k vector search over the same
corpus. The Python mount runs numpy's best shape for it — gather the eligible
rows, then one contiguous matrix-vector product in BLAS. The Mojo mount runs a
fused loop that checks each row's tag before touching its floats. Both arms
generate the corpus from one LCG and must return the same top-k before
anything is timed.

Unfiltered, numpy hands one matvec to Accelerate, and the hand-written loop
loses to it per core. Filtered, numpy has to gather, and the gather holds
the GIL: the numpy arm's cores column stays near a core and a half with
four handler threads behind it, while the Mojo mount spreads across its
threads (SPEC M25).

<!-- generated: mojo-mount -- edit bench/results, not this table -->
Source: [`mojo-mount-20261119T073505Z.json`](../bench/results/mojo-mount-20261119T073505Z.json) — 2026-11-19T07:35:05+00:00, commit `55606c80`.
Environment: Python 3.14.7; Apple M4 (10 cores: 4P+6E); 16 GB; macOS 27.2.1 (26B131); AC Power; wrk -c8 -d5s, 3 rounds, medians.

| selected | numpy rps | cores | rps/core | Mojo rps | cores | rps/core | throughput | per core |
|---------:|----------:|------:|---------:|---------:|------:|---------:|-----------:|---------:|
| 100 % | 35,911 | 1.42 | 25,290 | 44,062 | 4.15 | 10,617 | 1.22x | 0.42x (0.42x) |
| 25 % | 16,586 | 1.20 | 13,822 | 77,958 | 3.09 | 25,229 | 4.70x | 1.81x (1.82x) |
| 5 % | 44,615 | 1.45 | 30,769 | 114,131 | 2.36 | 48,360 | 2.56x | 1.58x (1.57x) |

Throughput and per core are Mojo over numpy: the median across rounds of the ratio within each round. In parentheses, the same per-core ratio from the medians block: median rps over median cores for each arm, which the columns to its left divide out to. Cores are the server process's CPU seconds over wall seconds across the measured window; both arms share one process, so the column is each arm's own load, measured one at a time. numpy 2.5.3.
<!-- /generated: mojo-mount -->

## Workers or threads, for a Mojo application

`m0serve` scales across cores by prefork (`--workers N`) for Python's
reasons: a GIL, an interpreter to fork before. A Mojo application under the Mojo host has neither, and
`M0_THREADS=N` serves it as N loops on N threads of one process (SPEC E27).
`uv run poe bench-host-modes` measures the two against each other on
`apps/ramp`: `now` is answered on the loop and measures the loop, `search` is
the table's compute view. Each arm is a fresh server; keep-alive, with the
keep-alive request cap off.

<!-- generated: host-modes -- edit bench/results, not this table -->
Source: [`host-modes-20261119T074238Z.json`](../bench/results/host-modes-20261119T074238Z.json) — 2026-11-19T07:42:38+00:00, commit `55606c80`.
Environment: Python 3.14.7; Apple M4 (10 cores: 4P+6E); 16 GB; macOS 27.2.1 (26B131); AC Power; wrk -c16,256 -d8s, 3 rounds, medians.

| route, connections | 1 worker rps | 4 workers rps | cores | p99 ms | RSS MB | 4 threads rps | cores | p99 ms | RSS MB | throughput | per core | p99 | RSS |
|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| now c16 | 246,887 | 200,278 | 2.48 | 0.11 | 45 | 198,953 | 2.55 | 0.12 | 34 | 0.99x | 0.96x | 1.02x | 0.77x |
| now c256 | 248,696 | 215,135 | 2.70 | 1.32 | 48 | 214,694 | 2.76 | 1.32 | 37 | 1.00x | 0.98x | 1.00x | 0.78x |
| search c16 | 30,916 | 107,379 | 3.97 | 0.46 | 45 | 106,580 | 3.97 | 0.47 | 34 | 0.99x | 0.99x | 1.02x | 0.77x |
| search c256 | 30,898 | 108,467 | 3.98 | 5.20 | 48 | 107,790 | 3.98 | 5.26 | 37 | 0.99x | 0.99x | 1.01x | 0.78x |

The last four columns are threads over workers: the median across rounds of the ratio within each round, so throughput and per core above 1.00x favour threads and p99 and RSS below it do. Cores and RSS are summed over the server's whole process tree; summed RSS counts a page two workers share twice. `now` is answered on the loop and measures the loop; `search` is the table's compute view.
<!-- /generated: host-modes -->

The modes serve the same requests at the same tail, and threads hold less
memory: one runtime instead of N. On this machine `wrk` runs out of cores
before the server does: one worker serves as many `now` requests as four.
Those rows compare CPU per request. The Linux run, the reading
of both, and why prefork stays the first recommendation (a worker that dies
is replaced; a loop that dies takes the process) are in
[loops-on-threads](notes/loops-on-threads.md) (DECISIONS D35). The x86-64
run, and the one place it disagreed, are in
[the-demo-in-its-own-image](notes/the-demo-in-its-own-image.md), which also
measures the modes on ONE core for the blobs deploy (D36).

## Non-goals, considered and rejected

- **`writev` for header/body split** — the response is already assembled
  into one buffer and sent with one syscall; vectored IO would not help
  until encode stops copying the body.
- **io_uring** — a different backend entirely; the epoll loop is not the
  bottleneck at current rates.

## Reproducing

wrk is not a dependency of this repo (same policy as gunicorn in the WSGI
doc). The shape of a run:

```bash
uv run poe build-all
uv run mojo build -I packages/m0-core/ -I packages/m0-http/ \
  apps/hello/server.mojo -o /tmp/hello_server
/tmp/hello_server &

wrk -t2 -c16 -d10s --latency http://127.0.0.1:8080/       # keep-alive
wrk -t2 -c16 -d10s -H 'Connection: close' http://127.0.0.1:8080/

# Syscall budget (the strace overhead inflates µs/call ~10×; use the
# calls and errors columns, not the time):
strace -c -p "$(pgrep -x hello_server)" & sleep 5; kill -INT %%
```

`scripts/bench_hello.sh` automates the matrix (baseline + concurrency
sweep) and prints a summary table.

The Mojo-mount table is `uv run poe bench-mojo-mount` (needs wrk; numpy is a
dev dependency), which waits for a quiet machine, asserts both arms agree,
and writes the artifact the table renders from. The workers-or-threads
table is `uv run poe bench-host-modes` (needs wrk; record from a clean
tree, then `uv run poe render-bench-docs`).
