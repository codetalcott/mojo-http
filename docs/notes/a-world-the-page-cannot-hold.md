# A world the page cannot hold — wired 2026-09-16

> A design note from the engineering record. The first application written
> for the Mojo-native stack rather than for the Python gateway: what it had
> to have that nothing in the tree provided, what was built for it, and
> what it leaves for the Mojo host.

**The piece.** `apps/blobs` is a shared lava lamp. A producer thread holds
up to sixteen blobs, steps them ten times a second, traces each into a
48-vertex polygon and publishes the whole state as one Datastar
`patch-signals` frame. The page is sixteen full-stage `div`s whose
`clip-path` is bound to a signal, so CSS draws and interpolates every
shape. A click drops a blob for everyone, the oldest evicted past sixteen.
The claim is the one a page cannot make for itself: one world, held by the
server and shared by every viewer, whose per-step work is bounded however
many viewers click. The step time on the page reports what the step costs;
it is not a benchmark.

**The order it was built in.** The metaball kernel (field, marching
squares, chaining, resampling) was prototyped and measured first, at
~276 µs a step on an M4 — two orders of magnitude inside a shared vCPU's
allowance at 10 Hz. Its remaining risk was correctness, and none of that
risk touches the server. So the server, stream and page were built first
over a stand-in kernel (`kernel.mojo`: each blob a circle, no merging)
that emits the same contract, and the metaball kernel replaces it behind
`trace` in a round of its own. `apps/blobs/test/test_kernel.mojo` checks
the contract rather than circles, so the replacement meets the same tests:
`NVERT` vertices, clear of the stage edge, vertex 0 at the smallest y,
ties by x, and negative shoelace area in page coordinates. That last rule
already has a finding waiting for it: the prototype's four loops at the
measured configuration wind −423, −12,783, **+893** and −482. The positive
one is almost certainly a hole the prototype kept, where the plan says to
keep outer loops only.

## What the application needed that nothing provided

Five things, each now built and gated:

1. **A `Views` table that also streams.** `ViewService` forwards `func`
   and `before_request` only, and no app had combined a table with the SSE
   hooks. `BlobsHandler` is that shape: the table dispatches, the struct
   holds a `BlobState` and wires the four hooks to its `DatastarStream`.
   Opening the stream is an `add_write` view, because subscribing a slot
   changes the viewer count.
2. **The current state for a new subscriber** (SPEC I24).
   `DatastarStream.open` either replayed a journal to a client presenting
   `Last-Event-ID` or joined it to the live feed. A stream of STATES wants
   neither: a replayed frame is wrong rather than late, and the live feed
   leaves a blank page until the next step, which for a paused producer is
   never. `DatastarStream(send_latest=True)` keeps the newest frame per
   url, by event id, and sends it at every `open`. It ignores the id a
   client presents, because a producer's ids restart with its process: a
   tab that saw step 5000 from the last process would otherwise be sent
   nothing until this process's steps passed 5000.
3. **A reconnect after the server closes cleanly.** Datastar 1.0.4's
   default retry does not reconnect after a clean close, which is what a
   draining server produces. The page asks for `retry: 'always'`, and
   `poe browser-blobs` restarts the server under two open tabs and
   requires both to reopen the stream and draw the new process's world.
4. **A bus refusal that can be seen** (SPEC I25). `publish_to_channels`
   dropped a frame over `BUS_MAX_FRAME` without a word, which, for a
   producer whose frame grows with its state, cannot be told apart from a
   producer that stopped. It now returns how many channels took the
   datagram. The producer counts every shortfall, and the smoke requires
   the count to be zero. A full stage is 9.6 KB, so the limit is about
   seven times away. At 10 Hz that is ~96 KB/s per viewer (0.77 Mbit/s),
   recorded per run.
5. **A drop channel and a viewer count that survive a fork.** A click is
   validated on the loop and must reach the producer thread;
   `lightbug_http/ring.mojo` would carry it between threads, but its memory
   is `malloc`'d, and in the host's normal case a click lands on a
   different worker from the producer. So `board.mojo` puts both on
   the pre-fork `SharedAtomics` page. The drop box is claim-then-store:
   a writer `fetch_add`s a sequence number and then stores the drop under
   it, and the reader applies a word only when the sequence inside it is
   the one it expects. A smaller sequence is a claim not yet written, so
   the reader waits for its next step. A larger one means a later drop
   overwrote the word, and it is counted as lost. The viewer count is one
   word per worker, which the producer sums. Phase 1 has one worker, so
   the sum has one term; the multi-writer case is tested by constructing
   a claim with no store.

## One process, and what that defers

`M0_WORKERS` above 1 is refused with exit 78. Serving from several workers
needs accept sharing, a click that lands on a worker other than the
producer's, and a viewer count summed across workers. All of that is the
Mojo host's job; written here by hand, it would be written once and then
deleted. The board is already laid out per worker, so the host only has
to size it and fork. What the host must meet, and what this app does not
yet prove, is the two-worker half: streams on both workers receiving every
step, a click on worker 1 reaching worker 0's producer, and a pause that
waits for the viewer count summed across workers.

`main` carries the host's first specification as comments: `[host]` marks
the lines every Mojo app with a producer writes (the listener, the pre-fork
page and bus, per-worker handler construction, a producer on the tick
owner handed every write fd, signals armed after the fork, a bounded join),
and `[blobs]` marks what belongs to this app (cadence, the board layout,
the producer body). Apart from the refusal, the app-specific lines are the
cadence and board configuration, and two arguments to the producer's
thread block.

## Found on the way

**`parse_json_number` killed the process on a non-UTF-8 byte** (SPEC G14).
It cut the number out of the body with `body[byte=start:i]`, and the byte
after a number is whatever the client sent: `{"x":1<0x80>}` asserted a
codepoint boundary and trapped. No app in the tree called it until the
drop view did. The module's other readers — `parse_json_int`,
`parse_json_field`, `parse_json_string`, `parse_json_bool` and
`has_json_field` — survived 200,000 fuzzed bodies with the key fixed and
bytes above 0x7F mixed in; the same run with `parse_json_number` added
trapped. The cut is now a byte-span slice, and `smoke-blobs` posts the body
over a socket.

## The gates

- `poe smoke-blobs` (every PR): frames at cadence, well-formed and full
  state; a corner drop clamped and reaching two streams; seventeen blobs
  evicting to sixteen; the newest state as the first frame after a pause,
  and nothing older; no steps with nobody watching; the drop cap and bad
  bodies; the idle slow-down; a drain with a held stream that exits 0
  without abandoning the producer; `M0_WORKERS=2` refused.
- `poe test-apps` (every PR, inside `test-all`): the kernel contract, the
  frame, the board. It is the first test task for an application's own
  modules: tests live in `apps/<app>/test/` with no `__init__.mojo`, and
  import the app's modules through `-I apps/`, as its server does.
- `poe browser-blobs` (pre-release): Chromium checks that the pinned
  bundle applies a patched `_`-signal to `clip-path`, that a click posts
  `x` and `y` and nothing else, and that two tabs survive a restart.
- `poe sabotage-blobs` (pre-release): each of sixteen rules broken in turn;
  the smoke must fail every time. Its first run missed one, which is
  worth keeping: removing the drop's clamp alone passes the smoke, because
  the producer advances the world before it traces and `advance` both
  clamps and bounces an out-of-band centre back inside. Three layers
  guard the band. On the wire, the sabotage now collapses the band
  itself, and the kernel test, which traces without advancing, catches
  the drop clamp on its own.
