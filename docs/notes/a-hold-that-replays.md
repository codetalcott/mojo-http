# A hold that replays — 2026-10-06

A design note from the engineering record. D65 is the decision; SPEC I33
names the capability. It retires the known issue "A WSGI hold replays
nothing on reconnect", open since 2026-09-17.

## The question

A plain `M0-Hold: stream` subscribed to the loop's `SSERegistry`, whose
`Last-Event-ID` handling was the redelivery filter alone
(`event_id > last_event_id`): a client that reconnected at 12 was not sent
12 again, and that was all the id bought. What was published while it was
away — a phone asleep, a proxy that dropped the stream — was gone. Only
`DatastarStream`, the Mojo-side fan-out, kept a journal (SPEC I10). The
documentation said "suppression only" since the day the earlier wording
("replay covers them") was found to be false, and an application that
believed it had dropped its own catch-up path; `desk` kept a poll beside
the stream.

For a server whose pitch is realtime from a synchronous view with no added
infrastructure, that was the one capability gap a real application met
first: every one of them had to keep a poll.

## What was built

**Each loop journals the last `--replay-frames` numbered frames it
delivered** (`M0_REPLAY_FRAMES`; 64, `DatastarStream`'s depth; 0 keeps
none), in `m0_http.sse.replay.ReplayJournal`, and a held stream that
reconnects with `Last-Event-ID` is caught up from it. One site does it,
`WSGIHandler._resume`, reached by both ways a hold lands in the loop's
registries: the inline subscribe (`--blocking-threads 0`) and the `h` frame
a pool thread sends — which is also how a Mojo mount's hold and a hold
mount's arrive, so they are covered without a line of their own.

The rules are `DatastarStream`'s (I30), carried over rather than
re-derived:

- **A first visit gets the live feed alone.** No `Last-Event-ID` means a
  new consumer, and replaying history onto a freshly rendered page is the
  defect SSE's own semantics avoid.
- **All or nothing.** A client the journal can serve whole gets every
  frame of its channel after the id it presented, in order, queued ahead
  of anything live. One it cannot — the id is below the journal's floor,
  or the frames would not fit the connection's 64 KB outbox — gets nothing
  from history. Served in part, it would hold a state with a hole in it
  and no way to know.
- **A gap is said, not shrugged at.** This is the one thing the WSGI side
  could not borrow: `DatastarStream` answers `caught_up(slot)` to the view
  that opened the stream, which then `send_to`s the current state. A WSGI
  view has already returned by the time the hold is taken. So the server
  tells the client instead: one unnumbered frame,

      event: m0-gap
      data: {"last_event_id":7,"head":12}

  then the live feed. A client listening for it fetches what it missed;
  one that is not sees an event type `EventSource` ignores. Unnumbered,
  so the client's `Last-Event-ID` stays where it was until the next real
  frame.
- **An id ahead of the counter is a gap too, and is clamped.** A server
  numbers from 1 each time it starts, so a client holding 5000 from the
  last incarnation presents an id this one never allocated. Taken
  literally — which is what the registry did until now — it suppressed
  every frame until the counter passed 5000: a silent starvation, found
  by `DatastarStream`'s author and fixed there in I30, and present on the
  WSGI side until this round. The subscription is clamped to the head and
  the gap frame goes out.

**The floor is one number for every channel, on purpose.** Ids are one
counter across every channel, so a client of a quiet channel whose id is
older than the floor may have missed nothing — a busy channel's frames
were what pushed the journal along. Telling would take a mark per channel
the journal ever dropped a frame of, which `DatastarStream` keeps and can
afford, because a stream has a handful of urls. m0serve's demo opens a
channel per visitor: that list would only grow. Bounded memory wins, and
such a client is told it may have missed something and fetches, which
costs one request; a larger `--replay-frames` makes it rarer.

**A respawned worker's journal starts at the counter.** Every worker's
loop receives every publish over the bus, so each journal sees the whole
cluster's frames from the moment it exists — and nothing before. The
handler reads the shared counter as it is built and sets the floor there,
so a client reconnecting to a fresh worker from before its birth is told
so rather than silently served the live feed alone.

**In memory only.** A restart begins an empty journal whose floor is
wherever the counter stands, and a reconnect across it is a gap, which is
the truth. `DatastarStream` offers `restore` for an application that
persists its journal; the WSGI side does not, because the application
that could persist frames is on the other side of a process boundary and
already has the record the frames were made from. The gap frame is the
restart's answer.

## What the gate found

The round was written as the repository asks: the smoke first, then the
piece under it. `smoke-django-realtime` phase 3b runs one round against
the default pool and again under `--blocking-threads 0`: two frames
missed and replayed in order ahead of a live one, with another channel's
frame left out; a client pushed past a 4-frame journal by five publishes
elsewhere, told so and served nothing from history; a stale id told so
and not starved.

The first run of the gap arm failed: the journal was 64 deep whatever the
flag said. `WSGIHandler.build` passed the depth to the constructor, but
the handler every pool thread and the executor's fallback are built by is
`for_options`, a second constructor call that passes what it was written
to pass. The pool path is the default under `--realtime`, so the flag
reached nothing a user would run. A unit test on the journal alone would
not have found it; the smoke did on its first run, which is the argument
for writing it first.

Phase 3's own resume assertion had to change. It resumed one PAST the last
id it knew, which the registry took literally and used to prove
suppression of the next publish. That id is one the server never
allocated — exactly the stale case above — and the server now reads it as
such. The phase resumes at the last id it saw instead, which is what a
client does, and proves the same thing: the frame it has is not re-sent,
the next one is.

## Not built

- A per-channel floor: the memory argument above.
- Persistence or `restore` on the WSGI side: the application has the
  record.
- Replay for a WebSocket hold: a browser cannot put `Last-Event-ID` on an
  upgrade, so no client could ask.
- A reconnect to a sibling that was behind on the bus: cross-worker
  ordering is best-effort (the-bus-and-its-doors.md), and a frame that
  arrives behind a newer one is inserted in id order, so it replays in
  order; one that never arrives moves nothing and is a defect of the bus,
  not the journal.
