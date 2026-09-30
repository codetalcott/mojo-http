# Accept sharing: workers sharing a listener share its connections — shipped 2026-09-05

> A design note from the engineering record. SPEC E16; the gate is
> `smoke-accept-spread` on both CI legs, the probe is
> `scripts/accept_spread.py`, the mechanism is
> `packages/m0-http/lightbug_http/accept_share.mojo` over
> `c/fdpass.mojo`.

## The finding

`--workers N` has every worker wait on the one listener the supervisor
bound, and whichever worker wakes first drains the backlog until `EAGAIN`.
On an idle box that is the same worker nearly every time, and a keep-alive
load — whose connections are accepted once and then held — runs at that
one worker's throughput for as long as they live. The Core ML embedding
app (`bench/embed_coreml`) served 1675 req/s on one worker and 1675 on two
spawned ones, with 197 of 200 warm connections on one pid
([MiniLM on the Neural Engine](coreml-embeddings.md)).

The probe opens N keep-alive connections, asks `/pid` on each while all
are open, and counts per worker. Two workers, the bare WSGI app, largest
share first, three shapes per row:

| platform, mode | burst 32 | ramp 32 @ 50 ms | burst 8 |
|---|---|---|---|
| macOS M4, fork | 32/0, 31/1 | 26–29 / 3–6 | 8/0 |
| macOS M4, spawn | 31/1 | 27/5 | 8/0 |
| Linux aarch64 (colima, 4 vCPU), fork | 23/9, 31/1, 27/5 | 26/6, 18/14, 26/6 | 6/2, 8/0, 7/1 |
| Linux aarch64, spawn | 23/9, 26/6, 25/7 | 21/11, 23/9, 26/6 | 7/1, 7/1, 8/0 |
| Linux, the 0.17.1 wheel, fork | 21/11, 16/16, 28/4 | 23/9, 27/5, 22/10 | 6/2, 7/1, 8/0 |

Linux's epoll wakes both workers and the second sometimes reaches
`accept` in time, so its bursts spread better than kqueue's and once in
five land within 2:1 — which is exactly what makes a "sometimes" gate
worthless. A ramp never spread on either platform. The kickoff's
"measure Linux first" question was therefore answered: one mechanism had
to serve both.

## What was tried and did not work, before this

Two wakeup tweaks behind a knob, both measured on macOS and reverted
(2026-09-04): a level-triggered listen with one accept per wakeup (a burst
still 31/1; the ramp balanced once at 17/15 and never again), and the same
plus `sched_yield()` after the accept (28/4). The loop re-enters `kevent`
in microseconds and wins the next race before its sibling is scheduled.
`EPOLLEXCLUSIVE` had already modelled worse for the related placement flake
(80 of 80 to one worker in every placement — it removes the race that was
giving the other worker its share). uvicorn's workers spread (123/77)
because a Python loop iteration is slow enough to lose races; that is not
a property to copy.

## The three candidates, and the measurement that chose

**Per-worker `SO_REUSEPORT` listeners.** The kernel distributes on Linux —
a two-listener model measured 13/19, 13/19, 21/11 for a burst of 32, a
4-tuple hash, so uneven per burst and just inside 2:1 on a bad draw. On
macOS the same model sent every connection to the last-bound socket: 32/0
three times, 64/0 twice (`bin/reuseport_model.py` in the session; the
measurement the ROADMAP had said was never taken). It would also have
undone D6 (a second server on the port must fail to bind), made a
respawn visible to clients (connections queued at a dead worker's own
listener are reset until it rebinds) and given `--spawn-workers` a
per-worker bind. Not built.

**An accept token in the shared page** (nginx's `accept_mutex`). The token
moves the *right* to accept, not a connection, and the right is worth
nothing to a worker that is asleep: a holder that releases after one
accept re-takes the token at its next pass, microseconds later, before the
sibling wakes — the same race, one level up. nginx bounds that with a
500 ms `accept_mutex_delay` on the non-holders and has had the mutex off
by default since 1.11.3. Making it a strict turn (release, poke the
sibling on its bus channel, refuse to re-take) needs a steal timeout for
a holder stuck in a slow inline view, and that timeout is a latency
hazard on every single connection that arrives while the holder is busy.
Not built; the reasoning is the record, since the flaw is structural
rather than a number.

**Passing the accepted descriptor.** The kickoff listed this as the
supervisor's job over the bus — most code, one more hop per connection,
last resort. Moved into the worker that won the accept, it is neither: the
acceptor keeps what it should keep and passes the rest with `SCM_RIGHTS`
over a per-worker `AF_UNIX` datagram channel created pre-fork (the bus's
shape), the receiver's loop drains that channel like a bus channel and
admits the socket through the accept path's own tail. Exact balancing,
both platforms, one listener kept (so D6, respawn, `--reload` and
`--spawn-workers` are untouched), and one `sendmsg` plus one `recvmsg`
per connection that changes hands. Built.

## The mechanism

- **Channels.** `AcceptShare(workers)` before the fork: one
  `SOCK_DGRAM` socketpair per worker, non-blocking, 64 KB buffers, every
  worker holding every send end. Under `--spawn-workers` the fds are kept
  across the exec and travel as `M0_ACCEPT_READ_FDS`/`M0_ACCEPT_WRITE_FDS`,
  and the worker adopts them by index as it adopts the bus.
- **The page.** `SharedAtomics` grew from one slot to
  `accept_share_slots(workers)`: slot 0 stays the event id, slot 1 is a
  rotation counter, and worker `i` owns the cache line at slot `8 + 8i`
  with three words — `state` (0 parked, a pass's start time in ns while
  inside one, −1 once it is leaving; 0 became "not started" and parked
  −2 on 2026-09-30, the correction under The pick), `active` (open connections,
  published at the end of every pass) and `pending` (connections passed
  to it and not yet admitted). A fourth, `taken`, was added on
  2026-09-29 (the correction under Leaving).
- **The pick.** On every accept the winner reads each sibling's line and
  names the least `active + pending`, ties to itself, scanning from a
  rotating start so equal siblings take turns; a sibling that has left or
  has been inside one pass for over 2 ms (a slow view running inline) is
  skipped, because the old race, for all its unfairness, sent such
  connections to the idle worker and this must not do worse.

  **Correction, 2026-09-30.** A worker's words read 0 until its loop's
  `start()`, and 0 was parked, so a sibling still starting was picked as
  an idle one with nothing to do. Nothing reads its channel until then,
  and in m0serve that is after the application's import (review record
  AR, from S1). With worker 1 held 3 s before its start
  (`M0_TEST_ARM_GAP_MS`), 16 of a burst of 32 went to it and each was
  answered 3.0 s late; with a SIGTERM inside the hold the supervisor
  exited 0 and every connection handed to the held worker was closed
  unanswered. Now 0 is `STATE_NOT_STARTED`, which a fresh page holds from
  before the fork with nothing written, `start()` and the end of every
  pass write `STATE_PARKED` (−2), and `pick` and `pick_for_leaver` skip a
  sibling that has not started as they skip one that has left. A
  replacement (a respawn, a reload's new worker) marks its index not
  started as it binds, its first act after the fork, keeping the
  predecessor's `pending` and `taken`; between the death and that bind a
  sibling reads what the dead worker last wrote, a stale pass (skipped as
  busy after 2 ms) or parked, and a connection sent then waits in the
  channel for the replacement, as one queued before the death does.
  `smoke-accept-spread` holds worker 1 and requires the burst answered by
  worker 0 within 1 s with nothing passed.
- **The hand-off.** `send_fd` with the peer address in the payload (the
  receiver need not `getpeername`), `pending` incremented on success, the
  acceptor's own reference closed. On any failure — the channel full, a
  sibling gone — the acceptor keeps the connection. Nothing is dropped.

  **Correction, 2026-09-28.** Incrementing on success was a race. The
  receiver could admit the connection and retire it at the end of its
  pass in the gap between the acceptor's `sendmsg` and the increment: the
  retire found nothing to take, `pass_end` floored the count at 0, and
  the late increment left that worker's `pending` one high for good, so
  every `pick` after it read the worker as a connection busier than it
  was (review record R5). Since #434 the acceptor raises the target's
  `pending` BEFORE the datagram is queued and takes it back if `send_fd`
  fails (`AcceptShare.send_with`), so the count is never below what is in
  flight.
- **The admission.** The receiver's loop registers its channel like a bus
  fd and drains it to `EAGAIN`; each descriptor enters `_admit_connection`,
  the accept path's tail factored out for the purpose: borrow a slot,
  non-blocking, Nagle off, the per-slot state reset, the eager read, the
  read registration, the pipelined tail. `pending` is retired at the END
  of the pass that admitted it, beside the `active` it publishes;
  retiring on receipt let a sibling be under-counted for a pass.
- **Leaving.** `_run_shutdown` stamps −1 and drains the channel once more
  before closing the listener, so a datagram sent in the last microseconds
  is served by the drain rather than closed unread at exit. `leave` wins
  over the per-pass stores, or the drain's own passes would un-announce
  it. A crashed worker's queued datagrams wait for the respawn, which
  inherits the channel by index.

  **Correction, 2026-09-29.** Draining once more did not close the
  window: nothing ordered a sibling's send before that last drain (review
  record B25). With the gap between `pick` and the send widened, an idle
  leaver exited about 50 ms after SIGTERM and a sibling's `sendmsg`
  succeeded 255 ms after that, into a channel nothing would read again,
  and its client got nothing until the whole server stopped. A hand-off
  that reached a leaver's drain before its first byte was admitted and
  closed 1.6 ms later as idle between requests, and its client read EOF.
  Both reproduced on Linux and macOS. Since then the two sides shake hands
  on the page, each writing its own word before it reads the other's. The
  sender raises `pending`, then reads the target's `state` again, and
  keeps the connection if the target has left. The leaver stores −1, then
  its drain runs on while `pending`, less what it has received, is above
  0. And a worker that has left passes what its channel delivers on to a
  sibling that has not (`AcceptShare.forward`), admitting it only when
  none is left. The wait trusts `pending` not to stay high, and a worker
  that died between taking a hand-off and retiring it at the end of its
  pass left it high for good, so a fourth word on each line, `taken`,
  publishes what a worker has received and not yet retired, and the
  worker that takes the index subtracts it (`start`).
  `test_handoff_leaving.mojo` forces each interleaving.

  **Correction, 2026-09-30: a worker that dies.** A worker that dies
  writes its line no more, and "a crashed worker's queued datagrams wait
  for the respawn" held only when a respawn came. The supervisor replaces
  nobody once it is stopping (D10), once it has spent its respawns (five
  deaths inside a second of their fork, or ten times the worker count
  within an hour; SPEC E36), or after an exit 0 or 78, and a worker
  killed while parked read as parked with no load for the rest of the
  server's life: `pick` handed it
  connections until its `pending` outgrew the acceptor's load, each into
  a channel nothing would read (review record RP). With `--workers 2` and
  worker 1 killed with SIGKILL until the supervisor stopped respawning
  it, 16 of a burst of 32 were accepted and never answered, forked,
  spawned, under `--reload` and on the Mojo host alike. The supervisor is
  the one process that learns of a death, and it holds the page (it made
  it before the fork), so it writes the mark: every reap goes through
  `_remove_pid`, which stores −1 in the index's `state` before anything
  decides whether to replace it (`mark_reaped`,
  `WorkerSupervisor.share_accepts`). Left rather than not started because
  a sender reads `state` again after raising `pending` and refuses only
  −1, so a sender that picked the worker before the reap and reads it
  after keeps the connection. A replacement is forked after the mark and
  writes not started over it as it binds. After the fix the same burst is
  answered 32 of 32 by worker 0, which passes none on.

  What is still lost is what a sender queued between the death and the
  reap, in `_supervise` the time for `waitpid` to return, in `--reload`'s
  polling supervisor up to its 300 ms interval: it waits in the channel
  until the server stops. The supervisor holds every channel's read end
  and could take those off and pass them on, but to be complete it would
  need the leaver's half of the handshake, a wait until the index's
  `pending` less what the dead worker had `taken` is drained, run by a
  process that otherwise only waits and forks, to cover a window that is
  one `waitpid`'s return outside `--reload`. Not built; the connections a
  worker held when it died are lost with it in any case.

  **Correction, 2026-09-29: the kernel's collector (macOS).** A hand-off
  whose sender has closed its copy, which is every hand-off, is held only
  by the message in flight until the receiver takes it, and macOS's
  collector of descriptors in flight (XNU's `unp_gc`) flushed it whenever
  it ran: the request discarded, the receive side shut, so the receiver
  read EOF and closed the connection unanswered. The collector follows
  only descriptors that are themselves in flight, so a channel that was
  merely open protected nothing, and any AF_UNIX socket closed on the
  machine, by any process, schedules a run. With another process doing
  only that, `--workers 2` lost 179 of 1600 requests made in bursts of 32,
  about half of the 361 hand-offs; with this fix, none. The macOS CI runner
  met it in two unit tests. Each channel's read end is now kept in flight
  in a pair of its own (`_anchor_channels`), so the collector follows the
  channel. The collector's scan holds the channel's buffer lock, and a
  receive made with MSG_DONTWAIT failed EAGAIN against it with a datagram
  queued, so `recv_fd` receives there without the flag, on a non-blocking
  channel, and waits out the scan. Linux's collector takes only sockets
  held by nothing but messages in flight, and none of this happens there.
- **One worker pays nothing.** The default `AcceptShare()` is inactive;
  every entry point is one Bool check. `M0_ACCEPT_SHARE=0` keeps the bare
  race under `--workers N` for an A/B.

The `msghdr` and `cmsghdr` layouts differ between the two libcs and are
written out in `c/fdpass.mojo` rather than derived: one seven-word
`msghdr` serves both (a `UInt64` field set to a small value writes glibc's
`size_t` and Darwin's `int`-plus-padding identically on a little-endian
target), while `cmsghdr` genuinely differs (a 12-byte header on macOS, 16
on Linux) and is branched at compile time.

## After

The same probe, the same machines, sharing on. Two rounds per mode in the
gate; three here:

| platform, mode | burst 32 | ramp 32 @ 50 ms | burst 8 |
|---|---|---|---|
| macOS M4, fork | 16/16, 16/16 | 16/16, 16/16 | 4/4, 4/4 |
| macOS M4, spawn | 16/16, 16/16 | 16/16, 16/16 | 4/4, 4/4 |
| Linux aarch64, fork | 16/16 ×3 | 16/16 ×3 | 4/4 ×3 |
| Linux aarch64, spawn | 16/16, 16/16, 17/15 | 16/16 ×3 | 4/4 ×3 |

And the knob-off arm, same binary: macOS 32/0 (ramp 24/8, burst 8 8/0);
Linux 21/11 and 32/0 (ramps 27/5, 23/9). The gate asserts the knob-off
skew on macOS only, where it is deterministic; on Linux it is this table.

## What it costs

`bin/ab_accept.py` in the session: the bare WSGI app, `wrk -t4 -c64`,
one server at a time, arms alternated, Apple M4. The `Connection: close`
rows run 6 s with a 32 s gap after each, because an 8 s run leaves ~80k
sockets in `TIME_WAIT` against macOS's ~16k ephemeral ports and the
keep-alive run that followed could not connect — the first A/B's zeros.

| configuration | load | req/s per round | p50 |
|---|---|---|---|
| one worker, before | keep-alive | 128.0k / 124.5k | 476 µs |
| one worker, after | keep-alive | 125.9k / 123.6k | 480 µs |
| two workers, knob off | keep-alive | 200.4k / 199.1k / 201.6k / 190.7k | 289 µs |
| two workers, sharing | keep-alive | 198.5k / 201.6k / 198.0k / 185.9k | 289 µs |
| one worker, before | close | 16.8k / 16.9k | 819 µs |
| one worker, after | close | 22.0k / 13.3k | 804 µs |
| two workers, knob off | close | 11.5k / 22.7k / 17.4k / 22.7k | 825 µs |
| two workers, sharing | close | 21.7k / 23.3k / 14.1k / 22.9k | 823 µs |

One worker loses nothing (the mechanism is not in its path). Two workers
tie on keep-alive — wrk's four threads already spread the bare race
across two workers, which is why the E15 note's hello rows never showed
the skew; a single client's burst does. The connection-close shape is
where a per-accept cost would show and it is inside the noise of a
same-machine client that churns 16k ports: the pre-change binary's own
two rounds differ by 40 %. The cost that exists is bounded and known —
one `sendmsg` and one `recvmsg` per connection that changes hands, a few
microseconds beside a ~50 µs connect-request-close.

## The payoff

The measurement E16 was opened for: the Core ML embedding app, two
spawned workers, two blocking threads each, `bench/embed_coreml/bench_serve.py`,
against the 1675 req/s of 2026-09-04 and uvicorn's 2586 on two workers.

`bin/payoff_coreml.py` in the session drove `bench_serve.py` one row at a
time, 15 s of `wrk -t4` POST `/embed` (one sentence) after 200 warm
requests, the coremltools 9.0 / CPython 3.12 environment of the earlier
note, Apple M4:

| shape | req/s | p50 ms | p99 ms |
|---|---:|---:|---:|
| m0serve, one worker, two blocking threads, c8 | 1698 | 4.69 | 5.21 |
| m0serve, two spawned workers, knob off, c8 | 1779 | 4.65 | 5.09 |
| **m0serve, two spawned workers, sharing, c8** | **3090** | **2.58** | **2.77** |
| uvicorn, two workers, c8 | 2510 | 3.16 | 5.32 |
| m0serve, two spawned workers, knob off, c32 | 1795 | 18.66 | 916.83 |
| **m0serve, two spawned workers, sharing, c32** | **3086** | **10.35** | **10.93** |
| uvicorn, two workers, c32 | 2548 | 10.74 | 31.31 |

The second worker now pays: 1.8x the single worker and 1.7x the same
binary with the knob off, 23 % past uvicorn's two workers, with a p99
a fifth of uvicorn's at c8 and a thirtieth at c32 — the knob-off p99 of
917 ms at c32 is thirty-two connections queued on one worker's two
threads. The bench's warm-up column still reads ~196/4: its 200 warm
requests are sequential one-shot connections, each closed before the
next opens, and a tie goes to the acceptor by design — a load with one
connection open at a time has nothing to balance, and the wrk rows are
what the mechanism exists for.

## Not covered, and why

- **`--threads`.** N loops in one process share the listener the same way
  and presumably skew the same way; the mechanism would work unchanged
  (a socketpair and a page are as good across threads) but the threaded
  mode is free-threaded-only, weekly-gated, and E16 names workers. A row
  of its own if a measurement ever asks for it.
- **A load-aware policy beyond connection counts.** `active + pending`
  balances connections, which is what a keep-alive load needs; a worker
  whose connections are all busy is not distinguished from one whose
  connections are idle. The 2 ms in-pass rule catches the inline case.
  Anything finer needs a signal the loop does not have, and the pool
  shape makes the loop's own time a poor proxy.
