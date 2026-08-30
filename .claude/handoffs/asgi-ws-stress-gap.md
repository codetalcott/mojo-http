# Handoff: the inverted ASGI WebSocket flake, and the stress gate that cannot see it

> **DONE — 2026-08-30.** The gate was extended and the outcome recorded in
> `docs/ROADMAP.md` under Recently resolved, "The WebSocket path is not
> stressed"; `SPEC.md` row L9 is widened and its caveat deleted.
>
> **The flake was a real bug and is now diagnosed.** It did not reproduce
> locally (150 rounds per mode, three runs) but reproduced on this change's
> own CI run, where the probe's new phase stamp named it: the **app-initiated
> close handshake**, not the flood phase. The server closes a WebSocket's TCP
> connection without waiting for the peer's Close reply, so the reply lands
> unread and the kernel sends RST. Recorded under ROADMAP's Known issues as
> "A WebSocket close races the peer's close reply"; the fix is a separate
> change. The brief below is kept as the record of what was known going in.

## Task

Two halves. The second is the deliverable; the first is what motivates it.

1. **Investigate** a single CI failure in the ASGI WebSocket probe under the
   loop inversion, on macOS.
2. **Close the coverage gap it exposed**: `poe stress-asgi` — the pre-release
   timing gate that exists precisely because shared CI runners cannot reproduce
   this family of race — drives only `scripts/chunked_keepalive.py`. It never
   touches the WebSocket path. The failure landed in the half the gate does not
   cover.

## The failure

Run `33294727932`, `smoke (macos-latest)`, 2026-08-30. Step
`Smoke test the ASGI executor under the loop inversion`, which is
`M0_INVERTED=1 uv run poe smoke-asgi`:

```
ConnectionResetError: [Errno 54] Connection reset by peer
the ASGI WebSocket probe failed
=== asgi.log ===
m0serve: bareapp.asgi:application on http://0.0.0.0:8088 (protocol=asgi workers=1) asgi-loop
Event loop started (kqueue, max_connections=1024)
inverted: the event loop runs inside asyncio (kqueue fd 24)
```

The server log ends there — it started, went inverted, and said nothing more.
The probe is `apps/asgi_bare/ws_probe.py`, invoked at `pyproject.toml:3801` as
`M0_PORT=8088 python3 apps/asgi_bare/ws_probe.py`.

## What has already been established — do not redo this

- **First failure in 12 consecutive runs.** The identical step passed 29
  minutes earlier on a nearly identical tree.
- **The change under test could not have caused it.** It touched
  `docs/*`, `CLAUDE.md` and `scripts/spec_sheet.py` — nothing a compiled smoke
  executes.
- **A rerun of the identical commit went green on both platforms**
  (`gh run rerun <id> --failed`). Do this first for any future occurrence; it
  is the cheapest discriminator between a flake and a regression.
- **Not reproducible locally**: macOS arm64, 1 clean run plus 5 rounds under
  six CPU hogs, 6/6 passed.

So: a genuine flake, unreproduced, in an area the repo already documents as
timing-sensitive. That is the starting point, not the conclusion.

## Why it matters rather than being noise

`CLAUDE.md` is explicit that this family's flakes have concealed real bugs
before — the executor slot-ownership race "passed CI with the bug live", which
is the stated reason `stress-asgi` exists at all and is deliberately NOT in CI.
A flake here has once been a real defect wearing a flake's clothes.

## The gap, precisely

Three factors were present at the failure, and **no gate combines them**:

| factor | covered by |
|---|---|
| WebSocket path through the executor | `smoke-asgi` — once, unloaded |
| `M0_INVERTED=1` (event loop inside asyncio) | `smoke-asgi` — once, unloaded |
| sustained CPU contention | `stress-asgi` — but only over `chunked_keepalive.py` |

`stress-asgi` (`pyproject.toml`, task `stress-asgi`) loops
`M0_PORT=$port python3 scripts/chunked_keepalive.py` for `M0_STRESS_ITERS`
rounds under `M0_STRESS_HOGS` CPU hogs. It sets no `M0_INVERTED` and runs no
WebSocket client.

`apps/asgi_bare/ws_probe.py` already takes `M0_PORT` from the environment, so
it is directly reusable — the shape of the fix is small.

## What to deliver

Extend `stress-asgi` to cover the WebSocket path, under load, in **both** the
ordinary and inverted modes. Keep the existing chunked rounds; this is an
addition, not a replacement.

Design constraints, all from the repo's own conventions:

- **`stress-asgi` stays out of CI.** It is a pre-release gate named in
  `docs/RELEASING.md`. Do not add it to `test.yml`.
- **Refuse a stray server rather than racing it.** The task already `pgrep`s
  the port because `SO_REUSEPORT` means a second bind SUCCEEDS and silently
  takes a share of connections, so "it passed" would mean nothing. Any new
  server it starts needs the same treatment.
- **Report which round and which mode failed**, as the existing loop does — a
  bare "failed" costs the next investigator the reproduction.
- **Do not lengthen a timeout to make a flake pass.** If the WS probe proves
  flaky under load, that is the finding, not an obstacle to it.

## If you do reproduce it

The likely region is the executor's WebSocket seam, which `CLAUDE.md` documents
at length. Worth reading before theorising:

- `websocket.send` is credit-gated on the same window as streams, seeded at
  `websocket.accept`; charge is on ENCODED frame bytes (`_ws_frame_bytes`).
- A held 101 records its generation AFTER the non-stream branch's
  `clear_stream`, and the abort path reads `slot_sse or slot_ws` — aborting a
  socket was once a silent no-op.
- Per-slot shim state belongs to the slot's CURRENT task (`_exec_slot_task`,
  `_task_gone`), because the loop recycles a slot the instant it closes a
  connection.
- Under `M0_INVERTED` a producer waiting for the loop waits for itself, and a
  direct job can overtake a disconnect on the FIFO channel.

`poe test-shim` (`scripts/shim_ownership.py --sabotage`) is the deterministic
half of these rules and is in CI; it drives the extracted shim through real
socketpairs with no server and no Mojo. If a hypothesis can be expressed there,
express it there — it is faster and it cannot flake.

## Success criteria

- `stress-asgi` exercises the WS path under load in both modes, and names the
  failing round and mode when it fails.
- A deliberate break in the WS seam makes the extended gate fail — sabotage it,
  per the repo's standing rule, rather than trusting that it would.
- Either a reproduction (with the round count and conditions), or an explicit
  record that N rounds under M hogs did not reproduce it. **A negative result
  stated with its numbers is a real outcome here**; an unstated one is how this
  gets investigated a third time.
- `docs/ROADMAP.md` records the outcome either way.

## Repo conventions you will need

- Branch from `main` (`git checkout main && git pull` first — protected branch,
  PR required). Do not branch from whatever is checked out.
- `uv run poe` for everything; `mojo` lives in `.venv`.
- Every guard gets a sabotage before it is believed.
- `docs/SPEC.md` row `L7` covers slot ownership on every PR (via `test-shim`).
  **`L9` is the one this work is about**, and it has already been narrowed to
  admit the gap:

      L9 | Slot ownership under CPU contention, on the STREAMED path |
           verified | `stress-asgi` (pre-release) — it drives
           `chunked_keepalive.py` only; the WebSocket path is not stressed

  Closing the gap means widening L9 back and deleting that caveat. That is the
  clearest signal the work is done, and `poe check-docs` refuses a row whose
  gate does not exist or does not run — so the row cannot be widened before the
  gate covers it.
