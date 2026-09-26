# The fairness probe judges order, on every pull request — shipped 2026-09-26

> A design note from the engineering record. SPEC E11, and E34's Linux arm;
> the gate is `Probe the handler pool's GIL hand-off for fairness`, the one
> step of test.yml's `pool-fairness` job; the probe is
> `scripts/pool_fairness_probe.py`, run by `poe probe-pool-fairness`.

## Why it moved into CI

`probe-pool-fairness` was a pre-release probe. Its first run on Linux found
a starvation the reference Mac had never shown
([a-slice-keeps-the-gil](a-slice-keeps-the-gil.md)), and a pre-release
probe would catch that starvation's return only when the next release was
cut. It now runs on every pull request on GitHub's Linux runner, which has
the 4 vCPUs of the box that found it, in a job of its own: Linux-only, and
the spec checker refuses a cited step that carries an `if:`, so it cannot be
a step of the smoke matrix. A timing probe also wants a runner with nothing
else running on it. The reference Mac keeps the macOS run before a
release.

## The latency verdict was too close to the machine

The probe judged latency. The fair arm had to hold a p99 under 25 ms and a
max under a quarter second. The negative arms had to break those bounds: the
turn disabled with a p99 over 50 ms or a max over 500, the keep rule
disabled by breaking the fair bounds. Before putting the probe on every pull
request, every arm was run again and again on a 4-vCPU Linux VM:

| arm | runs | p99 | max |
|---|---|---|---|
| fair | 68 | 9.7–20.7 ms | 21–97 ms, and one 247 ms |
| the keep rule off (12 s) | 43 | 25.9–34.3 ms | 120–609 ms |
| the turn off | 15 | 9.2–29.2 ms | 554–2237 ms |

A fair run came within 3 ms of its max bound once in 68. The keep rule's arm
broke its bounds with a p99 as little as 4 % over, and 20 of 43 of its maxes
fell under the quarter second. The convoy's lowest max was 11 % over its
floor. Every arm sat near a bound, and a gate like that fails on a noisy
runner rather than on the pool.

The max also cannot tell a starved waiter from a paused machine. A runner
that stops the process for 300 ms produces a 300 ms max on every connection
at once, and that is not the pool's doing.

## Order

The probe now judges ORDER. A request is passed over when a request sent
after it is answered first: the pool served someone else while it waited.
The ring hands jobs out in the order they were queued, so in a fair pool a
request is passed over only while its thread waits its turn for the GIL. A
starved waiter is passed over by everyone the two alternating threads serve.
A paused process answers nobody while it is stopped, so it passes nobody
over.

The count comes from each request's send and answer times, taken by the
client: for every request, how many requests sent after it were answered
before it. It is a Fenwick tree over answer order, visited from the last
request sent to the first, so thirty thousand requests take well under a
second. A fair run lets at most five requests be passed over by more than a
hundred later answers, and none by more than a thousand. At the probe's
load the pool answers about 2.5k requests a second, so a hundred later
answers is about 40 ms of the pool serving others while one request waits.

Measured on the same VM with the verdict as committed:

| arm | runs | requests passed over by more than 100 | the most passed over |
|---|---|---|---|
| fair | 23 | 0 or 1 a run | 30–107 |
| fair, the server stopped for 300 ms twice | 5 | 0 or 1 a run | 47–158 |
| the keep rule off (12 s) | 16 | 88–171 a run | 336–1115 |
| the turn off | 8 | 75–142 a run | 2442–3901 |

A fair run has at most 1 long wait and each old shape at least 75, against
an allowance of 5. The stopped server's five runs had a 315–320 ms max,
and the latency verdict failed every one of them; the order verdict passed
all five.

- **The allowance is five, not zero.** The keep rule stops the drops that
  reordered the waiters, but a waiter can still lose its place to its own
  5 ms timeout ([a-slice-keeps-the-gil](a-slice-keeps-the-gil.md), "Not
  done").
- **None may be passed over by more than a thousand.** That is about 0.4 s
  of the pool serving others. The first Linux run showed a different regime
  from the one above, with few starvations and long ones: a max of 575–735
  ms at a p99 of 8.6–16.6. A handful of long waits stays under the
  allowance, and each of them is passed over by more than a thousand.
- **Latency is still printed and recorded, but it is not the verdict.** The
  job's measurements (`scripts/emit.py`) carry each arm's long waits and the
  fair arm's p99 and max, so a drift shows up with its headroom before it
  turns into a failure.

## What the gate proves, and what it cannot

- **Every pull request, on Linux.**
  - The fair arm is in job order.
  - The turn disabled is not, which proves the probe sees E11's convoy.
  - The keep rule disabled is not, which proves it sees E34's starvation.
- **The thresholds are counts, and counts scale with throughput.** A much
  faster runner answers more requests per millisecond of waiting. The
  measurements record the fair arm's figures beside their limits for that
  reason.
- **Not macOS.** The keep rule's arm is not asserted there, because the old
  shape measured fair on the reference Mac. The fair and convoy arms under
  the order verdict have not yet been run there; that is the next
  reference-Mac run's.
- **Not what the order costs.** A pool that serialized every request fairly
  would pass. Throughput and isolation are other gates' business:
  `smoke-blocking-threads`, and the detached-loop A/B.

## Not done

- **A per-thread view.** The client sees requests, not threads. The pool's own
  histograms (`M0_POOL_DEBUG=1`) name the thread that waited, and a failure
  here is where to turn them on.
