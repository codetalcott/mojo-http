# Two pool A/Bs that need a quiet machine

Two questions the 2026-10 fork review could not answer on a shared machine,
because each is a difference of a few microseconds per request. Run them in
a release's quiet stage (docs/RELEASING.md): `mediaanalysisd` paused with
the owner's agreement, nothing else compiling, and never a `pkill` by name.

| record | arm A | arm B | when B shows (the rule below) |
|---|---|---|---|
| LF24 | `main`: the wake page's lane records and the thread block's records 64 bytes apart, each block from `malloc` | each record on a 128-byte line of its own (Apple silicon's line): both strides 128 and both blocks 128-aligned | B shows faster: take B |
| LF22 | `main`: a thread that parks looks at its lane socket once, non-blocking, after announcing the park | that look removed | report it; the owner rules |

**The rule, for both.** A measure differs when the two arms' ranges over the
rounds do not overlap. B shows when it differs from A in the same direction
at slow 1 and slow 2 (the pooled cells where a parked thread is woken), or
in the fair arm's `ms_per_request`. `scripts/probes/pool_ab.py` applies it
and prints the verdict; five rounds, and a second session's five when the
first is close.

## Build the arms

From a clean worktree of `main`, with `UV_NO_SYNC=1` exported. Copies of
`m0serve` must live in `bin/`, beside the runtime libraries it finds through
`@loader_path`.

```sh
uv run --no-sync poe build-all
uv run --no-sync poe build-serve
cp bin/m0serve bin/m0serve-A
uv run --no-sync mojo build -I packages/m0-http -I packages/m0-core \
  apps/pool_spike/server.mojo -o bin/pool_spike-A
```

Each B is one edit to `packages/m0-http/lightbug_http/offload.mojo`:

- **LF24**: `comptime _WAKE_LANE_STRIDE = 64` and
  `comptime _THREAD_STRIDE = 64` become 128 (`_WAKE_MAX_LANES` falls from
  126 to 63, which no configuration reaches), and the two blocks,
  `self.wake_base = external_call["malloc", Int, Int](_WAKE_BYTES)` and
  `self.thread_base = external_call["malloc", Int, Int](bytes)`, come from
  `external_call["aligned_alloc", Int, Int, Int](128, ...)` with the same
  size (each a multiple of 128; neither block is ever freed).
- **LF22**: delete the look in `_park_on_own`, the seven lines from
  `var polled = self._recv_datagram(` through `return polled^`.

Build each with `B` set to its record, then put the file back:

```sh
B=LF24   # or LF22, after its edit
uv run --no-sync poe build-serve
cp bin/m0serve bin/m0serve-$B
uv run --no-sync mojo build -I packages/m0-http -I packages/m0-core \
  apps/pool_spike/server.mojo -o bin/pool_spike-$B
git checkout -- packages/m0-http/lightbug_http/offload.mojo
```

and rebuild `bin/m0serve` from the clean file (`poe build-serve`) when both
are done.

## Run them

```sh
uv run --no-sync python scripts/probes/pool_ab.py LF24
uv run --no-sync python scripts/probes/pool_ab.py LF22
```

Each alternates the arms, A first in every round, over the pooled row of
`poe probe-pool` (`/fast`'s p50 on a pool of four beside 0, 1 and 2 blocked
threads, without the loop-only row that takes most of that task's fifteen
minutes) and the fair arm of `poe probe-pool-fairness` (five threads, twenty
connections, a CPU-bound view). Before every cell it records `uptime` and
the top of `ps -Ao pcpu,comm -r` beside the cell; a load average above 2,
or anything but the arm above a few percent of a CPU, is a round to throw
away and re-run.

## Where the results go

Each run writes `bench/results/pool-ab-<YYYY-MM>/pool-ab-<B>-<UTC>.json`: a
subdirectory, as one-off A/Bs are kept (`asgi-per-core-2026-10/` is the
precedent), which the bench renderer does not read. Commit the artifacts
with whatever the verdict changes, and record the verdict on the review's
LF24 and LF22 lines.

## What changes the code

- **LF24, B shows faster**: take it -- both strides and both alignments,
  which makes offload.mojo's three cache-line claims true on Apple silicon
  (`_WAKE_BYTES`'s "each lane on its own cache line", `_THREAD_STRIDE`'s
  "One cache line per thread", and `add_lane`'s "each lane's wake words are
  one cache line") -- with the artifact. B slower, or "mixed", is the
  no-change branch below.
- **LF24, B does not show faster**: the strides stay, but those three claims
  are false today on any machine: both blocks come from `malloc`, which
  promises 16-byte alignment, so a 64-byte record can straddle two lines.
  Correct them to say so, with the artifact.
- **LF22**: B does strictly less, so it can only tie or win. Report the
  difference in microseconds per request and as a share of the slow 1 and
  slow 2 medians, with the ranges; the look stays unless the owner rules
  otherwise.

## The results

Both ran on 2026-10-09 in 1.13.0's quiet stage, on an M4 (128-byte
lines) with `mediaanalysisd` paused, five rounds each, at a load average
of 1.4 to 2.1. Both verdicts are **no difference**, and both hold with
the rounds that crossed a load of 2, or had a desktop process above a
quarter of a CPU, thrown away.

| record | measure | arm A (`main`) | arm B | |
|---|---|---|---|---|
| LF24 | pooled p50, slow 1 | 0.1160 ms (0.1114–0.1292) | 0.1249 (0.1147–0.1281) | overlap |
| LF24 | pooled p50, slow 2 | 0.1235 (0.1148–0.1364) | 0.1231 (0.1046–0.1277) | overlap |
| LF24 | fair, ms a request | 0.658 (0.657–0.658) | 0.658 (0.658–0.658) | overlap |
| LF22 | pooled p50, slow 1 | 0.1262 (0.1251–0.1333) | 0.1240 (0.1147–0.1308) | overlap |
| LF22 | pooled p50, slow 2 | 0.1244 (0.1206–0.1271) | 0.1265 (0.1220–0.1317) | overlap |
| LF22 | fair, ms a request | 0.658 (0.658–0.658) | 0.658 (0.658–0.658) | overlap |

LF24 took the no-change branch: the strides stay, and the three claims are
corrected. LF22's look costs about 2 µs a request either way, under 2 % of
either median, in opposite directions at slow 1 and slow 2: nothing
measurable, so it stays. The artifacts are `bench/results/pool-ab-2026-10/pool-ab-LF24-20261009T042627Z.json` and `bench/results/pool-ab-2026-10/pool-ab-LF22-20261009T042937Z.json`.

A first pass, run straight after `stress-asgi`, was discarded whole: its
twenty hogs had stopped, but the load average they left was 20 to 4
through every round.
