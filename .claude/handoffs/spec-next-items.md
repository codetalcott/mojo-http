# Handoff: four open spec items, and a technique to generalise

Written 2026-08-30, just after v0.15.1. Ordered by value, but they are
independent — take them in any order, or one and stop.

---

## STATUS — worked 2026-08-30, by two sessions in parallel

| item | status | outcome |
|---|---|---|
| 5. phase stamps | **done** | 13 probes stamped; `poe check-phase-stamps` holds it, sabotage-proven |
| 1. gate A4 | **done, and it found a live bug** | the WebSocket close linger was never bounded |
| 3. the inventory | **done** | 1 of 3 candidates is a real gap; 2 should not be re-proposed |
| 4. B8 | **done** | split into B8 + B9, both `out of scope` |
| 2. Autobahn | **answered — recommendation FLIPPED** | the suite does NOT catch the §5.5.1 bug |

**Item 1 is the headline, and the bet below paid.** Gating an ungated
mechanism found a real defect in under an hour. The WebSocket close linger
(RFC 6455 §5.5.1) re-armed its deadline on EVERY loop pass rather than once,
pushing it two seconds into the future about once a second, so the idle sweep
never overtook it. A peer that received Close and never answered held its slot
for the life of the process — the exact leak the linger's own comments say it
exists to avoid; measured still holding at 40 s. Fixed by arming only when the
deadline is still zero, at all four sites. `--idle-timeout`,
`scripts/idle_timeout_probe.py` and `poe smoke-idle-timeout` are new; A4 →
`verified`, and **L16 is new for the BOUND**, separate from L15 for the order,
because L15's 64-way concurrent close phase passes on both broken servers.

One correction to the plan below: the probe it proposes ("opens a connection,
sends nothing, and asserts the server closes it") would test the HEADER
deadline. A slot's idle deadline is stamped in `_finish_response`'s keep-alive
branch, so a client that says nothing never has one.

**Item 2's answer changes the recommendation, and the reason is structural.**
Autobahn scored `fe26113` (the known-violating build) and the fixed build
identically — section 7, 37 cases, 24 OK / 3 INFORMATIONAL / 10 FAILED, case
for case. Its fuzzing client always initiates the close itself, and the bug was
on the APP-initiated path: no conformance client can make a server's
application close first. `ws_probe.py`'s close-order phase tests something
Autobahn cannot reach, which is an argument that the hand-written probe was the
right instrument rather than a stopgap. The suite is still worth having — it
found real failures that ship today (reserved close codes echoed rather than
failed 1002, an invalid-UTF-8 close reason, messages ≥ 64 KB refused at
`MAX_PENDING_BYTES`) — but not on the argument this handoff made for it, and
the ROADMAP's "the bar is unambiguous and the result is comparable" needs
correcting when six of those failures are a deliberate cap.

**A finding neither item asked for.** The Autobahn run surfaced "the
executor's channel would not take an inbound message; it is lost", and it
reproduces trivially: inbound ASGI WebSocket messages are DROPPED, silently,
once the executor's submit channel fills — 2881 of 3000 lost at 4 KB, and loss
starts after roughly the first 70–120. The outbound direction is credit-gated
and the inbound direction has no backpressure at all, and the two are coupled:
the outbound gate blocking the app's `send` is what stops it calling `receive`,
which is what stops the drain that then loses inbound messages. In ROADMAP's
Known issues with `scripts/ws_inbound_loss_repro.py`. NOT fixed — the fix is a
read-path design change (keep the frame on the socket, take the slot off the
read set) rather than a patch, and that is the user's call to schedule.

The original handoff follows unedited: its reasoning is the record of why this
work was chosen, and is worth reading against the outcomes above.

## Why these exist

`docs/SPEC.md` is a requirements traceability matrix: 142 rows, each naming
the gate that proves it. `poe check-docs` refuses a row whose gate does not
exist or does not run, so a row cannot claim more coverage than exists — but
nothing can check that a gate tests what its row *says*. An audit on
2026-08-30 read every row against its gate and corrected about a fifth.

These four are what that audit and the v0.15.1 release left open. Read
`.claude/handoffs/asgi-ws-stress-gap.md` first if you want the precedent: it
asked for a coverage gap to be closed on the strength of an argument, the gate
was built, and it found a real RFC 6455 violation that had shipped in every
release. That is the pattern these items are betting on again.

---

## 1. Gate A4 — the idle connection timeout

**Its priority changed in v0.15.1, and this is the whole argument.** The
WebSocket close fix (RFC 6455 §5.5.1: having sent Close, wait to receive one)
bounds its wait with the idle sweep. In `event_loop.mojo` the linger is set at
three sites and every one is gated:

    :1302   elif slot_ws[s] and config.idle_timeout > 0:
    :1367   if slot_ws[s] and config.idle_timeout > 0:
    :1383   if slot_ws[s] and config.idle_timeout > 0:

with `WS_CLOSE_LINGER_NS` (`:69`) written into `slot_idle_deadline`. The code
comment says why: "with idle timeouts off there is nothing to bound a peer
that never replies, and holding the slot forever is worse than the reset."

Row A4 says: *"no gate asserts a connection is closed for idling."*

So **an ungated mechanism is now the bound on a shipped correctness fix.** If
the idle sweep regresses, a WebSocket peer that never answers Close holds its
slot forever — exactly the leak the fix's own comments say they are avoiding,
and it will present as slot exhaustion under real traffic rather than as a
failed test.

**What to build.** A probe that opens a connection, sends nothing, and asserts
the server closes it after the idle timeout — plus the inverse, which is the
half that makes it a test: a connection kept active past the timeout must NOT
be closed. `scripts/header_timeout_probe.py` is the closest model and already
asserts both directions for the *header* deadline (a silent connection is
answered 408; a keep-alive gap is not).

**The wait is the problem, and there is no shortcut yet.** `idle_timeout` is a
`ServerConfig` field (`server_config.mojo:48`) defaulting to **60 s**, and —
checked, not assumed — there is **no `M0_*` variable and no CLI flag for it**.
A probe that waits out the default would add a minute to `smoke-serve`. So the
first decision is how to make it testable: expose it (which A3, the keep-alive
request cap, also wants and would make a natural pair), drive it from a Mojo
test against a constructed `ServerConfig`, or use an app that sets it. Decide
that before writing the probe — it shapes everything after.

**Then extend it to the thing that now depends on it:** a WebSocket peer that
receives Close and never replies must have its slot reclaimed at
`WS_CLOSE_LINGER_NS`, not held. That is the assertion v0.15.1 actually needs
and does not have.

Flip A4 to `verified` when done. `poe check-docs` will refuse the flip if the
gate does not exist.

---

## 2. Autobahn|Testsuite (I13) — and a decisive experiment to run first

The case is now evidential rather than aspirational: the bug v0.15.1 fixed was
a **close-handshake ordering violation**, which is the kind of thing a
conformance suite exists to find. The WebSocket implementation here is
hand-verified against RFC text, and hand-verification missed a spec-order
requirement that had shipped in every release.

**Run this before committing to the work.** `fe26113` is the commit
immediately before the fix — a build with a known, fully characterised RFC
6455 §5.5.1 violation. Build it, point Autobahn's fuzzing client at it, and
see whether the suite catches it.

    git worktree add /tmp/prefix fe26113   # do not disturb main's build
    # build there, serve apps/asgi_bare, run Autobahn against it

- **If it catches it**, that is the strongest possible argument for the
  investment, stated as a measurement instead of a hope — and it belongs in the
  ROADMAP entry and the PR.
- **If it does not**, that is worth just as much, and it changes the
  recommendation. Say so plainly rather than building it anyway.

Either way record the number of cases and the pass rate; the bar the row
should claim is whatever was actually measured, not "517/517" copied from
another project's README.

**Cost shape.** Autobahn is a Python package and normally dockerised. It needs
its own CI job, and CI is already ~25 minutes — consider whether this belongs
in `Tests`, in a weekly cron beside `py-canary.yml`, or as a pre-release step
in `RELEASING.md`. The repo has all three precedents and the choice should be
argued in the PR, not defaulted.

---

## 3. The structural gap — inventory it, do not guess

The v0.15.1 bug came from a shape, not a specific oversight: **proven once,
unloaded, by a smoke; stressed not at all.** The measure of how little that
guarantees is exact — reverting the `websocket.send` credit gate was caught on
round 1 by the extended `stress-asgi`, and **passed the old chunked-only gate
30 of 30 under 8 hogs**.

Candidates with the same shape, each covered once and unloaded:

| path | smoke |
|---|---|
| `--realtime` holds (SSE and WS on a WSGI lane) | `smoke-django-realtime`, `smoke-django-realtime-ws` |
| mounts (several apps, one process) | `smoke-hybrid` |
| the handler pool | `smoke-blocking-threads`, `smoke-pool` |

**Produce the inventory before building anything.** For each: what would a
concurrent, contended version exercise that the current one does not, and is
there a plausible race there at all? Some of these may be genuinely fine —
`smoke-pool` already deals work across threads, and `probe-pool` is a
pre-release timing gate for that path. A finding of "this one does not need
it, because X" is a real result and should be written down so it is not
re-proposed.

Where a gap is real, the `stress-asgi` extension is the template: two ports so
`SO_REUSEPORT` cannot let a restart overlap its predecessor, both loop modes,
the mode asserted from the server's banner rather than from the variable, and
a failure that names its mode, round and phase.

**Sabotage anything you build both ways** — a gate that would not have caught
a real defect is worse than no gate, because it is believed.

---

## 4. B8 is mis-stated — split it

    | B8 | External desync suite (PortSwigger, h2spec) | planned | ROADMAP: A conformance-suite tier |

Both halves are wrong as a promise:

- **h2spec needs HTTP/2**, which is `out of scope` here — row **A18**,
  "terminate at a proxy", with **C7** ("HTTP/2 reset-flood limits") refusing
  downstream of it. A `planned` row promising h2spec contradicts a refusal in
  the section above it.
- **The PortSwigger scanner probes a proxy/server PAIR** for disagreement about
  framing. It is not a parser conformance suite, and this server has no proxy
  in front of it in any gate.

The real, useful half is **parser fuzzing** — already its own row (G13), and
cheap here because the decoder is a pure function over bytes with its own unit
suite. So: retire B8's h2spec half to `out of scope` with that reason, and
either fold the desync half into G13 or state plainly why a pair-scanner does
not apply.

Smallest item on this list; do it while touching the sheet for something else.

---

## 5. Generalise the phase stamp

**This is what turned a two-investigation mystery into an on-sight
diagnosis.** The CI failure was an unhandled `ConnectionResetError` whose
traceback named `recv_exact` — a helper four phases share. It said which CALL
reset, never which PHASE was being proven, and two investigations assumed the
wrong one. A phase stamp named it immediately: *the app-initiated close
handshake*, not the flood phase.

The pattern is ~10 lines, in `apps/asgi_bare/ws_probe.py`:

    PHASE = "startup"

    def phase(name):
        global PHASE
        PHASE = name
    ...
    except OSError as exc:
        fail("%s: %r" % (PHASE, exc))

**None of the other probes carry one** — verified: `chunked_keepalive.py`,
`half_close_probe.py`, `pipeline_probe.py`, `header_timeout_probe.py`,
`large_request_probe.py`, `drain_idle_probe.py` all have zero mentions of a
phase.

The handler prints the traceback AND the stamped phase — keep both. The
comment above `PHASE` explains why in the words of the failure that motivated
it, and is worth reading before copying: a traceback naming a shared helper
says which CALL failed, never which PHASE was being proven.

This is cheap, mechanical, and pays only when something fails — which is
exactly when you cannot afford to be guessing.

---

## Recommended order

1. **The phase stamps** — an hour, no design decisions, and it makes every
   later failure in items 1 and 3 cheaper to read. Do it first for that reason.
2. **A4**, because a shipped fix depends on an ungated mechanism.
3. **The inventory** in item 3 — the thinking, before any building.
4. **The Autobahn experiment** against `fe26113`, which decides item 2 on
   evidence.
5. **B8**, whenever the sheet is open.

## Conventions

- Branch from `main`: `git checkout main && git pull` **first**. Protected, PR
  required. (Branching from whatever was checked out cost three rebases in one
  session.)
- `uv run poe` for everything; `mojo` lives in `.venv`.
- Every guard is sabotaged before it is believed, and the sabotage asserts its
  own failure message, not just a non-zero exit.
- Verify the behaviour against a running server BEFORE writing the assertion
  that pins it. That is how the audit's mis-citations were found, and how the
  C3 probe avoided recording "the server cuts the connection" when it actually
  answers 413 and closes while the client is still writing.
- Moving a row's status is part of the work, not follow-up. `poe check-docs`
  refuses a claim its gate does not support, so the sheet cannot get ahead.
