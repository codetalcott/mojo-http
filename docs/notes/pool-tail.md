# The pool's fast-route tail was the keep-alive cap — 2026-09-07

> A design note from the engineering record. It answers the question
> [elastic-pool.md](elastic-pool.md) left open: the mixed-workload table's
> pooled rows held a fast-route p99 of 2–4 ms where Granian's row held
> 0.5–0.6 ms on the same application, BENCHMARKS.md conceded the 4x, and
> nobody had found the mechanism. This note names it, with the instruments
> that placed it and the A/B that moves it by six times the run-to-run
> spread. The time was never on the server's request path. It was
> `ServerConfig.max_keepalive_requests`, which was 100: the server closed
> every keep-alive connection after its hundredth request, the client
> reconnected, and one reconnect in a hundred requests IS the 99th
> percentile. Granian has no such cap. The default is now 1000 (nginx's),
> `--max-keepalive-requests` / `M0_MAX_KEEPALIVE_REQUESTS` set it (0 =
> never), and at equal shape the two servers' rows are the same row.

## The instruments

`scripts/probes/bench_slow.py`: Django, `wrk -t2 -c16`, a fresh server per
arm and round, arms alternated, with N `curl` loops on `/slow?ms=200`
beside the fast route — the mixed-workload script's shape. Apple M4 (4
performance and 6 efficiency cores). A system daemon (`mediaanalysisd`)
held a full core throughout the session; every row here is a
within-session ratio and the absolute figures are a busy laptop's.

Three instruments split a request's time, and the split is the finding:

- Under `M0_POOL_DEBUG=1` each pool thread histograms three intervals per
  job and prints them at shutdown: the wait on the ring from the loop's
  push to the thread's pop, the wait for the GIL from the pop to the
  re-attach, and the service from the re-attach to the completion.
- The loop prints its own cadence beside them: how many waits, how many
  capped to the 1 ms pool wait, how many returned LATE past the timeout
  they asked for — a capped wait that returns at 6 ms is a loop thread
  the kernel did not run for five — and how many passes ran over 1, 2, 4
  and 8 ms.
- `M0_ACCESS_LOG=true` logs every request's time from its first header
  byte read to its last response byte handed to the kernel.

What none of them can see is the interval between one response's last
byte and the next request's first — which is where the answer was.

## Where the time was not

`--workers 4 --blocking-threads 4`, the table's row, on the pinned
CPython 3.13.6, one slow view in flight:

| where | p50 | p99 | p999 | max |
|---|---:|---:|---:|---:|
| **the client (wrk)** | 150 µs | **7–11 ms** | | 26 ms |
| the server, first header byte to last response byte (2.5 M fast requests) | 122 µs | **1.35 ms** | 1.6 ms | 29 ms; 4 requests over 5 ms |
| a pool thread's ring wait | 48–56 µs | 0.3 ms on the hot thread, 1.3–1.5 ms on a cold one | 1.5 ms | 2.5–7 ms |
| a pool thread's GIL wait | <1 µs | <2 µs | 3–10 µs | 1.3–3.6 ms |
| a pool thread's service | 32 µs | 160 µs | 192 µs | the slow view |
| the loop, waits returning more than 1 ms late | | 6 of 1.1 M per worker | | 5 over 2 ms, none over 4 |
| the loop, passes over 1 ms | | 0 | | |

Every server-side component is under 1.5 ms at its 99th percentile, the
loop is never late, and the request path from arrival to send accounts
for a p99 of 1.35 ms. The 7–11 ms the client saw was between the
client's clock and the server's kernel. (The server-side 1.35 ms is real
and is ours, and it is the aged wake's shape: a job behind a slow view
waits `POOL_WAKE_AGE_NS` plus up to the loop's 1 ms wait cap before a
sibling is woken, which is the cold threads' ring-wait p99.)

The handoff's five hypotheses, two rounds each, alternated, 3.13, four
workers unless noted:

| arm | slow=0 p99 | slow=1 | slow=2 | rps | verdict |
|---|---:|---:|---:|---:|---|
| the default | 1.2 / 7.3 ms | 7.4 / 11.4 | 6.3 / 9.2 | 83–86k | bimodal at slow=0, as recorded |
| `M0_QOS=1` (the loop at user-interactive QoS) | 6.7 / 6.9 | 9.7 / 6.8 | 9.3 / 6.4 | 84–86k | not placement |
| `M0_POOL_TURN=0` (no hand-off barrier) | 0.5 / 1.0 | 10.2 / 7.3 | 9.4 / 6.4 | 85–88k | not the barrier |
| `gc.freeze()` after the import | 6.2 / 9.6 | 6.4 / 9.1 | 6.1 / 9.4 | 83–86k | not the GC |
| `--workers 2 --blocking-threads 4` | 5.8 / 6.1 | 5.1 / 5.3 | 5.8 / 6.3 | 66–69k | |
| `--workers 1 --blocking-threads 4` — Granian's shape | 4.2 / 6.1 | 1.0 / 1.6 | 1.7 / 1.6 | 30k | smaller with fewer processes |
| granian, `--workers 1 --blocking-threads 4` | 849 / 783 ms | 976 / 929 ms | 859 / 252 ms | 28k | a GIL build saturated on one interpreter; the table's 0.6 ms is 3.14t |

Queue or service (hypothesis 1): neither. The cyclic GC (2), the hand-off
barrier (3), the loop's wait cap (4, single-digit late waits per million)
and macOS placement by QoS (5) each land inside the default's own spread.
The one thing that moved it here was the number of server processes, and
that turned out to be a symptom of the mechanism below rather than a
cause: each reconnect costs more when four loops are parked on the
listener.

## On the interpreter the table is recorded on

The same arms under the 3.14t swap (`poe py314t-try`, granian 2.8.2
installed into the swapped venv, the binary rebuilt inside it), where the
pool is parallel (`M0_POOL_PARALLEL`, elastic-pool.md), two rounds:

| arm (3.14t) | slow=0 p99 | slow=1 | slow=2 | rps | p50 / p90 |
|---|---:|---:|---:|---:|---:|
| `--workers 4 --blocking-threads 4`, the table's row | 1.6 / 3.1 ms | 2.8 / 2.7 | 7.7 / 4.8 | 60–63k | 187 µs / 750–940 µs |
| `--workers 1 --blocking-threads 4` — Granian's shape | 3.0 / 3.7 | 2.2 / 2.7 | 6.3 / 3.7 | 49–57k | 270 / 345 |
| granian, `--workers 1 --blocking-threads 4` | 0.61 / 0.65 | 0.52 / 0.51 | 0.51 / 0.52 | 48–53k | 300 / 380 |

Two things changed with the interpreter, and neither was the answer.
The four-worker row's per-job SERVICE on a pool thread went from a p50
of 32 µs and a p99 of 160 µs on the GIL build to 96 µs and 1.5 ms:
sixteen Python threads that really run in parallel, in four processes,
on a ten-core laptop that also hosts the client, and the view pays their
preemption inside its own wall time. And at the equal shape the
comparison stopped being about shape: one m0serve worker with four
threads had a BETTER p50 and p90 than Granian's worker and a p99 four to
six times worse. Its server-side path, over 1.9 M fast requests: p50
247 µs, p99 **449 µs**, p999 596 µs, 0.02 % over 1 ms — under Granian's
client-side p99 — while the client saw 1.3 / 4.8 / 5.7 ms in the same
run. Neither the idle spin (`M0_POOL_SPIN_US` at 0, 1 and 10 µs) nor the
eager wakes (`M0_POOL_ELASTIC=0`) moved it out of the 2–7 ms band.

## The mechanism: one request in a hundred reconnected

What differed between the two servers, for the same client, was not in
either's per-request timing. It was a policy. `max_keepalive_requests`
was 100: after a connection's hundredth request the server answered
with `Connection: close` and closed it, and the client opened a new one.
Granian, uvicorn, gunicorn and hypercorn have no such cap. Counted
directly, five seconds of `wrk -t2 -c16` against each server in the same
shape:

| server | requests in 5 s | client-side sockets left in `TIME_WAIT` |
|---|---:|---:|
| m0serve, `--workers 1 --blocking-threads 4` | 280,176 | **3,105** — one per hundred requests |
| granian, the same shape | 258,734 | 2 |

So exactly one request in a hundred paid a TCP reconnect — a `connect`
on the client, an accept in the loop's next pass — and one in a hundred
is the 99th percentile by construction. It never appeared in the
server's own timing because the closed connection's clock stopped at its
last response and the new connection's clock started at its first header
byte; the reconnect sat between them, in the one interval no instrument
above covers.

The magnitude was the box's. On macOS the client's ephemeral range is
16,384 ports (`net.inet.ip.portrange` 49152–65535) and a closed socket
holds one for 2 × MSL = 30 s (`net.inet.tcp.msl` 15000), so at 550
reconnects a second a forty-second arm burns the whole range, `connect`
starts hunting for a free port, and the tail grows through the run and
into the NEXT fresh server's run. That is the bimodality elastic-pool.md
recorded for main's own binary: the first arm after a pause read 1–2 ms
and the one that followed it 6–8, the difference being the previous
arm's sockets still in `TIME_WAIT`. Four workers made each reconnect
dearer than one — the listener's readiness wakes every loop parked on it
(the herd of elastic-pool.md) and the accept may be handed to a sibling —
which is the shape effect in the first table. And Granian's row was
clean in every recording because it never reconnects and it runs last
in each round.

## The A/B, and the default

`M0_MAX_KEEPALIVE_REQUESTS` was added for the measurement and kept, with
`--max-keepalive-requests` over it. 3.14t, arms alternated with a 32 s
pause between them so one arm's `TIME_WAIT` sockets expire before the
next starts, two rounds and a third of the decisive pair:

| arm (3.14t) | slow=0 p99 | slow=1 | slow=2 | rps | max |
|---|---:|---:|---:|---:|---:|
| `--workers 1 --blocking-threads 4`, cap 100 | 0.70 / 0.62 / 0.66 ms | 2.95 / 1.86 / 1.63 | 3.23 / 3.83 / 3.07 | 52–56k | 10–19 ms |
| the same, cap 0 | **0.54 / 0.50 / 0.51** | **0.54 / 0.46 / 0.53** | **0.58 / 0.49 / 0.58** | 53–58k | 1–11 ms |
| the same, cap 1000 | 0.53 / 0.49 | 0.46 / 0.45 | 0.64 / 0.53 | 54–58k | 2–16 ms |
| granian, `--workers 1 --blocking-threads 4` | 0.55 / 0.54 / 0.56 | 0.52 / 0.51 / 0.51 | 0.53 / 0.53 / 0.53 | 48–53k | 1–3 ms |
| `--workers 4 --blocking-threads 4`, cap 100 | 1.5 / 1.5 | 3.7 / 2.2 | 3.7 / 4.0 | 61–64k | 12–26 ms |
| the same, cap 0 | 1.33 / 1.33 | 1.24 / 1.33 | 1.31 / 1.35 | 64–66k | 4.5–5.8 ms |

With the cap off, m0serve in Granian's shape IS Granian's row — 0.45–0.58
ms across the slow levels, a shade under it at slow=1, with 8–10 % more
throughput — and the four-worker row is flat at 1.3 ms from 1.5–4.0,
its maxima 5 ms from 25. A cap of 1000 is indistinguishable from none at
the 99th percentile (one reconnect per thousand requests is a p999
matter) and is what nginx has shipped since 1.19.10, so it is the new
default; a deployment that wants no cap sets 0, and the cap smoke (SPEC
A3) pins 100 explicitly so the gate is independent of the default.

What remains at four workers — 1.3 ms against 0.5 at one — is the box:
sixteen parallel Python threads and four loops beside a two-thread client
on ten cores, the service-time inflation measured above. It is not the
table's claim, which is about the stall, and an equal-shape m0serve row
belongs in that table beside Granian's; the re-recording that adds it
is the next step, and BENCHMARKS.md's concession is rewritten with it.

## What did not survive, for the record

- "Queue wait or service time" was the right first question and the
  answer was neither; the split instrument stays (`M0_POOL_DEBUG=1`) for
  the next tail question, because it is what proved the server's path
  clean in an afternoon.
- The idle spin, the GIL hand-off barrier, the cyclic GC and QoS
  placement were each measured and each moved nothing; none was changed.
- The Linux arm (the handoff's fifth hypothesis) was not run: the
  mechanism was named on macOS with an A/B six times the spread, and it
  is a TCP-level policy with the same shape on both kernels, only the
  `TIME_WAIT` arithmetic differing (Linux holds a port 60 s across a
  28,000-port range).

## The mixed-workload table, re-recorded

`scripts/bench_mixed_workload.sh` under the 3.14t swap on the tree with
the cap at 1000, three rounds, the equal-shape row added
(`bench/results/mixed-workload-20260907T032546Z.json`, against
`mixed-workload-20260906T225838Z.json`), fast-route p99 medians with the
min–max across rounds:

| configuration | slow=0 | slow=1 | slow=2 | fast rps |
|---|---:|---:|---:|---:|
| `--workers 4` (the control) | 0.8 ms (0.8–0.8) | 189.7 (188.7–191.0) | 193.6 (192.4–194.0) | 60k |
| `--threads 4` (the control) | 0.7 (0.7–0.7) | 192.7 (191.2–195.5) | 198.4 (196.8–199.6) | 60k |
| `--workers 4 +bt=4` | 1.4 (1.4–1.5) | 1.3 (1.3–1.3) | 1.3 (1.3–1.3) | 62–66k |
| `--threads 4 +bt=4` | 0.9 (0.9–0.9) | 0.9 (0.9–0.9) | 0.9 (0.9–1.0) | 45–47k |
| **`--workers 1 +bt=4`** — Granian's shape | **0.5 (0.5–0.5)** | **0.4 (0.4–0.5)** | **0.5 (0.5–0.6)** | 50–58k |
| granian bt=4 | 0.5 (0.5–0.6) | 0.5 (0.5–0.5) | 0.5 (0.5–0.5) | 48–53k |

The pooled rows are flat to the tenth of a millisecond across three
rounds where the previous artifact's two-round medians read 2.6 / 2.8 /
4.1; the equal-shape row and Granian's are the same row; the controls
still fail by a factor of two hundred, which is what they are for.

One number in the artifact is recorded rather than explained. The
`--workers 4` control's fast-route THROUGHPUT is 60k against 80k in the
two recordings of 2026-09-06 — and against 55–58k in every recording
before them, so 80k was the outlier. A pinned-3.13 A/B on that shape,
two rounds each with a 32 s drain, rules out the two mechanisms this note
touches: cap 1000 91.5k / 91.5k, cap 100 89.8k / 92.4k, `M0_ACCEPT_SHARE=0`
90.9k / 91.6k. The row's p99 fell from 4.0 ms to 0.8 with the reconnects
gone, and its throughput is not a claim the table makes; the comparator
drift check flagged it, as it should, and the artifact carries the
acceptance stamp for the cap change that the same check flagged on the
pooled rows.

The same shape run again on 3.14t the next morning (`bench_slow.py`,
two rounds, 32 s drains, the daemon paused) read 82.5k / 82.9k at cap
1000 and 81.4k / 84.6k at cap 100 — the 80k of the two 2026-09-06
recordings, with the cap making no difference to throughput and only
the maxima telling them apart (10–13 ms at cap 100, 2–5 ms at 1000).
So the 60k was a state of that one recording — all three of its rounds
agreed with each other and with nothing before or after — and not of
the code. What that state was is not known; the first recording attempt
that evening, refused by the guard at its second round, had read 81k
for the same row twenty minutes earlier.

