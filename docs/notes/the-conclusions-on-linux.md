# Do the benchmark page's conclusions hold on Linux? Two of four do not — 2026-09-08

> A design note from the engineering record. Every artifact
> [docs/BENCHMARKS.md](../BENCHMARKS.md) renders is macOS arm64, and the page
> says so — as a caveat about absolute rates. This note asked the stronger
> question, because
> [inversion-on-a-constrained-box.md](inversion-on-a-constrained-box.md) had
> just found a RATIO between two m0serve configurations inverting across
> platforms. Two of the page's four headline conclusions invert, and both
> inversions are in m0serve's favour.

## What was run

The three headline shapes, in the `m0lin` container (Linux aarch64, an
8-vCPU VM), against the same comparators at the same versions: granian
2.8.2, uvicorn with and without uvloop. Three rounds, arms alternated
within each round, every comparator re-measured beside every arm, CPU from
`/proc/<pid>/stat` deltas. Artifacts in
[`bench/results/linux-2026-09/`](../../bench/results/linux-2026-09/).

Each arm's spread across the three rounds was 0.8–2.1 %, comparators
included — tighter than the macOS runs usually are, which is what makes
the ratios below readable.

## The answer

| conclusion, as the page states it | macOS | Linux | |
|---|---|---|---|
| Slow-view isolation | 194 ms → 1.3 ms | 1430 ms → 1.35 ms | holds, larger |
| The HTTP layer, zero Python | 200k rps/core | 210k | holds |
| ASGI vs `uvicorn --loop asyncio` | 2.01x rps, 1.25x/core | 1.84x, 1.73x | holds |
| **ASGI vs uvicorn+uvloop, per core** | **0.89x — behind** | **1.11x — ahead** | **inverts** |
| **WSGI vs Granian, one worker one thread** | **0.98x rps, 0.99x/core** | **1.08x, 1.03x** | **inverts** |

The page's two "No" answers are macOS-specific, and the platform where
essentially every deployment runs says the opposite — narrowly, but on
both.

## One mechanism explains both

| | macOS | Linux |
|---|---|---|
| ASGI executor | 117,185 rps @ **1.60** cores | 102,203 @ **1.06** |
| WSGI, one worker one handler thread | 183,787 @ 1.73 | 274,337 @ 1.96 |
| WSGI, app inline on the loop (no handoff) | 118,652 @ 0.99 | 112,687 @ 1.00 |

Read the third row first: the shape with NO cross-thread handoff is the
same on both platforms. Every row that has one is dramatically better on
Linux. The handoff — a datagram or a ring push plus a wake — is materially
cheaper on epoll and futex than on kqueue, and the handoff is exactly what
m0serve's two-thread shape pays for its isolation. That is a single
coherent explanation for both inversions, and it predicts the direction of
the third: the executor needs 1.60 cores on macOS to reach a rate it
reaches on 1.06 here.

## What this does NOT say

The absolutes are not comparable and no conclusion here rests on them.
This is a VM on a Mac — two layers of virtualization — and server and
client share the VM's 8 cpus where the macOS box has 10 real cores. Linux
WSGI at 274k against macOS's 184k is not "Linux is 1.5x faster"; it is a
different machine through a hypervisor. What transfers is the within-run
ratio, which is the page's own doctrine.

It also does not say the page is wrong about its own box. Every macOS
figure stands. What changed is the scope of the claim built on top of it.

## Why this matters beyond the wording

**Performance work has been aimed by macOS profiles.** The loop's user
space, the pool's ring handoff, the elastic wake rules — each was measured,
ranked and accepted on this Mac. If the handoff is cheap on Linux, then
handoff-targeting levers are worth less there and per-request user-space
work is worth more, and effort has been allocated by a ranking that may not
hold where the software runs. That is a stronger argument for a Linux
measurement capability than any wording fix, and it is the reason this note
exists rather than a footnote.

## What was built alongside it

Recording a Linux artifact at all turned up three provenance gaps in
`bench_record.py`, each the same shape as reporting a confident value that
could not be determined:

- **`git_dirty` answered `False` where git could not be asked.** A
  container copy of the tree has no `.git`, and that field exists to WARN a
  reader that the commit may not be the code. It answers `None` now, and
  `render_bench_docs.py` treats "cannot tell" as "must not back a rendered
  table".
- **`git_sha` was empty for the same reason.** `BENCH_GIT_SHA` states it,
  and `BENCH_SOURCE_STAMP` — `scripts/probes/source_stamp.sh`'s hash, which
  the sync verifies against the Mac — is what makes stating it more than a
  claim.
- **`cpu` and `cores_physical` were empty on arm64 Linux**, because
  `/proc/cpuinfo` has no `model name` line there. On a page whose whole
  argument is per-core, a blank core count is not a cosmetic defect.

And one guard: `newest(kind)` picks by filename with no notion of platform,
so a Linux artifact of the same kind dropped into `bench/results/` would
have silently become the source for a table whose prose describes an Apple
M4 and its performance and efficiency cores. It is refused now, naming the
remedy. Before the guard the only complaint was the comparator-drift check
firing on every row — which tells you to "re-record on a quiet machine",
the wrong remedy entirely.


## A second Linux environment, and a correction — 2026-09-09

The table above rests on ONE Linux environment: an 8-vCPU aarch64 container
on a Mac, with the server sharing cpus with the load generator. A rented
box removes that confound, so the same three shapes were run on a Linode
`g6-dedicated-4` — 4 dedicated vCPU, x86-64, AMD EPYC 7713, Python 3.13.15,
Debian 12 — for about twenty-five cents. Artifacts beside the others in
`bench/results/linux-2026-09/`.

| conclusion | macOS (M4) | container (8 vcpu, arm) | Linode (4 vcpu, x86) |
|---|---:|---:|---:|
| WSGI vs Granian (rps) | 0.98 | **1.08** | **0.97** |
| WSGI vs Granian (per core) | 0.99 | **1.03** | **0.98** |
| ASGI vs uvloop (rps) | 1.44 | 1.19 | 1.05 |
| ASGI vs uvloop (per core) | 0.89 | 1.11 | 1.01 |
| ASGI vs `uvicorn --loop asyncio` | 2.01 | 1.84 | 1.85 |

**The WSGI inversion does not reproduce.** Two of the three environments
put m0serve a couple of percent behind Granian, exactly as the benchmark
page says; the container is the outlier. That claim, made here and in
BENCHMARKS.md on 2026-09-08, was overstated and both are corrected.

**The ASGI per-core inversion survives in direction and collapses in
size.** Both Linux environments answer at or above parity (1.11, 1.01)
against macOS's 0.89, so "per core, uvloop is ahead" really is
macOS-specific — but on real x86-64 hardware it is a tie, not a lead, and
the honest statement is that the magnitude is unsettled.

**Read this second environment with its spread in hand.** Its per-arm
spreads are 4.2–12.6 %, against the container's 0.8–2.1 %, so a 0.97 here
does not cleanly refute a 1.08 there — it declines to reproduce it, which
is weaker and is all that is claimed. Its absolute rates are also about a
quarter of either other environment (28.7k rps against 102k and 117k on
the ASGI row): four vCPUs of a 64-core EPYC, with the load generator on
the same four.

## What that says about renting hardware

The rented box was supposed to be the quieter instrument. **It was
noisier** — 4.2–12.6 % against the container's 0.8–2.1 % — so at this size
it buys nothing the container does not already give, and the container
stays the right default. Two plausible reasons, not separated here: four
vCPUs is too few for a server and a load generator that between them want
about six, and a "dedicated" vCPU on a 64-core part still shares memory
bandwidth and last-level cache with other tenants.

The general lesson is the one the disagreement itself teaches: **one Linux
environment is not "Linux."** The first pass answered a platform question
with a single machine and got a result that a second machine did not
confirm. Where two environments disagree, the claim is that they disagree.
