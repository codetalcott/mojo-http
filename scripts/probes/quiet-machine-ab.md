# Two pool A/Bs that need a quiet machine

Two questions the 2026-10 fork review could not answer on a shared machine,
because each is a difference of a few microseconds per request. Run them in
a release's quiet stage (docs/RELEASING.md): `mediaanalysisd` paused with
the owner's agreement, nothing else compiling, and never a `pkill` by name.

| record | arm A | arm B | changes the code when |
|---|---|---|---|
| LF24 | `main`: the wake page's lane records and the thread block's records 64 bytes apart, each block from `malloc` | each record on a 128-byte line of its own (Apple silicon's line): both strides 128 and both blocks 128-aligned | B is faster, by more than either arm's own spread |
| LF22 | `main`: a thread that parks looks at its lane socket once, non-blocking, after announcing the park | that look removed | never in the run that measures it: report how much B is faster, if it is, and the owner rules |

## Before each timing

Record these beside the numbers, every time:

```sh
uptime
ps -Ao pcpu,comm -r | head -8
```

A load average above 2, or anything but the arms above a few percent of a
CPU, is a run to throw away.

## Build the arms

From a clean worktree of `main`, with the shared venv activated
(`. .venv/bin/activate`: `m0serve` embeds the first Python on `PATH`) and
`UV_NO_SYNC=1` exported. Copies of `m0serve` must live in `bin/`, beside the
runtime libraries it finds through `@loader_path`.

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

## Run them, arms alternated

With `B` set to the record being measured. The wake's cost, as `/fast`'s
latency on a pool of four beside zero, one and two blocked threads: the
pooled row of `poe probe-pool`, without its loop-only row, which takes most
of its fifteen minutes and has no pool in it.

```sh
B=$B python3 - <<'EOF'
import os, statistics, sys
sys.path.insert(0, "scripts")
from pool_spike_probe import run_config
cells = {}
for r in range(5):
    for arm in ("A", os.environ["B"]):
        for slow in (0, 1, 2):
            got = run_config("bin/pool_spike-" + arm, 4, slow, 300)
            cells.setdefault((slow, arm), []).append(got["p50"])
for (slow, arm), p50 in sorted(cells.items()):
    print("slow=%d %s p50 median %.4f ms, range %.4f-%.4f"
          % (slow, arm, statistics.median(p50), min(p50), max(p50)))
EOF
```

The handoff under contention, as `poe probe-pool-fairness`'s fair arm: five
threads, twenty connections, a CPU-bound view. Its `ms_per_request` is a
request's share of the pool, and `long_waits` must stay within its bound in
both arms:

```sh
for r in 1 2 3 4 5; do for arm in A $B; do
  port=$(python3 -c 'import sys; sys.path.insert(0, "scripts"); from probelib import free_port; print(free_port())')
  bin/m0serve-$arm bareapp.wsgi:application --app-dir apps/wsgi_bare \
    --port $port --blocking-threads 5 > /dev/null 2>&1 & pid=$!
  python3 scripts/pool_fairness_probe.py $port \
    | grep -E '^(ms_per_request|p99_ms|long_waits) ' | sed "s/^/$arm $r /"
  kill $pid; wait $pid
done; done
```

## Reading it

A difference shows when the two arms' ranges do not overlap, in the same
direction at slow 1 and slow 2 (the cells where a parked thread is woken),
or in `ms_per_request`. Five rounds each, as above, and a second session's
five if the first is close.

- **LF24**: if B shows, take it -- both strides and both alignments, which
  makes the docstrings' "one cache line" true on Apple silicon -- and record
  the arms' medians and ranges with the change. If it does not, record that
  at five rounds a cell, and the strides stay.
- **LF22**: B does strictly less, so it can only tie or win. Report the
  difference in microseconds per request and as a share of the slow 1 and
  slow 2 medians, with the ranges; the look stays unless the owner rules
  otherwise.
