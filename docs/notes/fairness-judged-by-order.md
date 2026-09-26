# The fairness probe judges order, on every pull request — shipped 2026-09-26

> A design note from the engineering record. SPEC E11, and E34's keep arm;
> the gate is `Probe the handler pool's GIL hand-off for fairness`, the one
> step of test.yml's `pool-fairness` job; the probe is
> `scripts/pool_fairness_probe.py`, run by `poe probe-pool-fairness`.

## Why it moved into CI

`probe-pool-fairness` was a pre-release probe. Its first run on Linux found
a starvation the reference Mac had never shown
([a-slice-keeps-the-gil](a-slice-keeps-the-gil.md)), and a pre-release
probe would catch a regression only when the next release was cut. It now
runs on every pull request on GitHub's Linux runner, in a job of its own:
Linux-only, and the spec checker refuses a cited step that carries an
`if:`, so it cannot be a step of the smoke matrix. A timing probe also
wants a runner with nothing else running on it. The reference Mac keeps the
macOS run before a release.

At its first load the runner caught the barrier's convoy (E11) and not the
starvation that motivated the move (E34): it answered the keep rule's old
shape in order ("GitHub's runner did not starve the first load", below).
The load it runs now starves every runner measured ("A load that starves
every runner").

## The latency verdict was too close to the machine

The probe judged latency. The fair arm had to hold a p99 under 25 ms and a
max under a quarter second. The negative arms had to break those bounds: the
turn disabled with a p99 over 50 ms or a max over 500, the keep rule
disabled by breaking the fair bounds. Before putting the probe on every pull
request, every arm was run again and again on a 4-vCPU Linux VM (a KVM
guest, Intel Xeon at 2.1 GHz), at the first load: four pool threads,
sixteen connections, a 0.3 ms view:

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
hundred later answers, and none by more than a thousand. At the first load
the pool answered about 2.5k requests a second, so a hundred later answers
was about 40 ms of the pool serving others while one request waits; at the
current one it answers 1.2-1.5k, and a hundred is 70-80 ms.

Measured on the same VM with the verdict as committed, at the first load:

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

## GitHub's runner did not starve the first load

The pull request's first CI run failed the keep rule's arm, and the
failure was the runner's answer, not noise:

| arm | the VM above | GitHub's Linux runner, first run |
|---|---|---|
| fair | 0 or 1 long waits, the most 30–107 | 0, the most 15 (p99 8.4 ms, max 10.9 ms) |
| the turn off | 75–142, the most 2442–3901 | 42, the most 6297 (max 2036 ms) |
| the keep rule off | 88–171, the most 336–1115 | 0, the most 63 (p99 12.6 ms, max 26.9 ms) |

The pull request shipped with the arm opt-in, a pre-release run on the KVM
guest, and the search for a load that starves the runner went on in the
next one.

## A load that starves every runner

GitHub's runners are not one machine. Five passes of a sweep put the probe
on 33 of them, and the first load's keep arm split them by CPU:

- every run on an AMD EPYC 7763 starved (42 of 42);
- every run on an Intel Xeon (Platinum 8370C and 8573C, 6973P-C) or an AMD
  EPYC 9V45 answered in order (14 of 14);
- the AMD EPYC 9V74 went both ways (4 and 4).

The KVM guest starved as well. The split has one cause, and it is
arithmetic rather than noise.

With the keep rule off, a thread drops the GIL between the jobs of its 1 ms
slice. Each drop wakes the longest waiter, which finds the GIL taken again
and queues behind the others, so each drop moves the queue round by one. At
the slice's end the hand-off wakes whoever the rotation left at the front.
A slice of k jobs makes k − 1 such drops, and with w threads waiting:

- if k − 1 is a multiple of w, the queue turns full circle, the hand-off
  goes round, and nobody starves;
- if k − 1 is one short of a multiple, the front is the thread that held
  the GIL before this one: two threads alternate and the rest starve, as
  [a-slice-keeps-the-gil](a-slice-keeps-the-gil.md) traced on the guest;
- in between, some threads cycle and some starve.

A starved thread is woken on every slice and loses the race each time, so
it waits until it wins one, which took up to four seconds on the runners.
How many jobs a slice holds is set by a request's share of the GIL: the
view plus the machine's own per-request cost. The sweep reads the share
off the fair arm as the run's length over its answers, since the pool runs
one view at a time.

| machine | a request's share, first load | jobs a slice | four threads (three waiting), the rule off |
|---|---|---|---|
| the KVM guest | 0.43 ms | 3: two drops | two alternate, two starve |
| AMD EPYC 7763 | 0.335–0.341 ms | 3 | two alternate, two starve |
| Intel Xeon 8370C, 8573C, 6973P-C; AMD EPYC 9V45 | 0.315–0.332 ms | 4: three drops | full circle, in order |
| AMD EPYC 9V74 | 0.325–0.334 ms | 3 or 4 | in order 4 times, starved 4 |

A 0.3 ms view put a slice on the boundary between three jobs and four, at
a third of a millisecond, and each machine's overhead picked the side. The
same count accounts for the other loads the sweeps tried, wherever the
share sat clear of a boundary. At 0.3 ms, three threads or five starved the
runners and not the guest, and at 0.45 ms four threads did the same: the
guest's slice holds one job fewer than theirs at both.

**The load now: five threads, twenty connections, a 0.65 ms view.** A
request's share is 0.67–0.70 ms on the runners and 0.80–0.84 ms on the
guest. That is two jobs a slice on all of them, one drop per slice against
four waiters, so two threads starve. Any share between 0.5 and 1 ms gives
two jobs, and the view spins on the clock, so no machine can bring the
share under 0.65 ms. Only a machine spending more than 0.35 ms of its own
on a request would leave the window, about twice the slowest measured.
The fair arm records the share in the job's measurements with 1 ms as its
limit, so a drift toward the edge shows as headroom before it shows as a
failure.

The fourth pass ran ten runners of five CPU types (AMD EPYC 7763, 9V74,
9V45; Intel Xeon 6973P-C, 8573C), two 12 s runs of each arm on each. The
guest ran five of the fair and keep arms, three of the turn's and two of
the control:

| arm | ten runners (20 runs) | the KVM guest |
|---|---|---|
| fair | 0 long waits, the most 10–22 | 0, the most 46–68 |
| the turn off | 12–116, the most 2596–17892 | 17–32, the most 4943–10789 |
| the keep rule off | 29–81, the most 1232–6105 | 73–100, the most 656–1071 |
| the keep rule off, four threads (the control) | 0, the most 7–19 | 0, the most 15–19 |

The control is the arithmetic's own negative arm. At the same 0.65 ms, four
threads are three waiters and one drop a slice, a rotation that reaches
every thread. The arithmetic says they stay in order with the rule off,
and they did, on every runner and on the guest. Three threads and views of 0.55 and
0.75 ms starved everywhere too. Five threads won on margin: the rule off
leaves at least 29 requests passed over by more than a hundred, where three
threads left as few as 6.

With the keep rule on there are no drops inside a slice, the hand-off goes
round whatever the count, and the order no longer depends on the machine.
That is what the rule is for, and the arm now shows it on every pull
request. The instrument is `scripts/probes/fairness_sweep.py`.

## What the gate proves, and what it cannot

- **Every pull request, on Linux, at one load.**
  - The fair arm is in job order.
  - The turn disabled is not, which proves the probe sees E11's convoy.
  - The keep rule disabled is not, which proves it sees E34's starvation.
    `M0_FAIRNESS_EXPECT_STARVATION=0` skips this arm, for a machine that
    answers it in order. None is known.
- **The keep arm rests on arithmetic, and the arithmetic has an edge.** A
  machine whose per-request cost put a request's share over 1 ms would hold
  one job a slice. It would make no drops, and the arm would answer in
  order. The share is recorded on every run for that reason.
- **The thresholds are counts, and counts scale with throughput.** A much
  faster runner answers more requests per millisecond of waiting. The
  measurements record the fair arm's figures beside their limits for that
  reason.
- **Not macOS.** The order verdict has not been run on the reference Mac,
  and neither has this load. macOS's condition variable is not glibc's, and
  whether the rotation above happens there was not measured. The Mac's next
  pre-release run is the first. If its keep arm answers in order, that is a
  finding about macOS: record it, and run the other two arms with the arm
  skipped.
- **Not what the order costs.** A pool that serialized every request fairly
  would pass. Throughput and isolation are other gates' business:
  `smoke-blocking-threads`, and the detached-loop A/B.

## Not done

- **A per-thread view.** The client sees requests, not threads. The pool's own
  histograms (`M0_POOL_DEBUG=1`) name the thread that waited, and a failure
  here is where to turn them on.
