# Latest wins after a stall — 2026-10-26

A design note from the engineering record. SPEC I44 is the row; D57 is
the decision it works within.

## The question

A reading of [hyperlith](https://github.com/andersmurphy/hyperlith), a
Clojure framework on Datastar, against this tree. Its render loop keeps
one rule per connection: render for a connection only once its previous
frame has been taken by the socket. A subscriber that stalls is skipped,
and the moment it drains it is rendered the current state. Nothing is
queued, nothing is lost that matters, because every frame is the whole
state.

The stream of states here, `DatastarStream(send_latest=True)` (SPEC
I24), had the first half of that and not the second. A frame a full
outbox refused was counted (`refused()`) and dropped for that slot alone
(D57), and the next broadcast superseded it. That holds while the
producer keeps broadcasting. A producer that pauses after the refused
frame, as the blobs demo's does when nobody is watching and as any
dashboard's does between changes, leaves the stalled tab on the state
before the refusal for as long as it stays connected. The stream-deadline
note called the next frame the right degradation; for a paused producer
there is no next frame.

## What was found

The fix needs nothing from the loop. `_drain_outboxes`
(`lightbug_http/loop/streams.mojo`) calls `sse_drain_slot` on every idle
stream slot every pass, and a slot is idle whenever its last send landed.
So a slot's outbox fills only while the kernel cannot take bytes, and
`drain` is called exactly when the stalled subscriber has room again.
That is hyperlith's "previous frame taken" signal, already present.

## What was decided

`DatastarStream.drain`, under `send_latest` only, queues the newest frame
for the slot's url after clearing the outbox when the slot's last-seen id
is below it. The frame goes out under its own id, so the registry
advances the slot past it and the live feed does not send it twice; the
next drain carries it, and the one after finds the slot current. A frame
that never fits the outbox is refused again, through the same cap. The
refusal count is left as it was: the refusal happened, and a count that
grows is still worth logging.

The change stream (the default) is deliberately left out. A reconnect's
replay is its catch-up (I30), and a change frame sent again at drain
would be a change applied twice. The stream-deadline note's retiring
condition for that case stands: close the stream at the cap so the client
reconnects and replays.

## What it costs

One scan over a stream's urls per drain of a state stream, a handful at
most. One extra frame per state a subscriber missed, never more, since a
current slot is queued nothing.

## What would retire it

A state stream whose frames are routinely larger than the outbox, where
the catch-up can never fit and the subscriber is told nothing. The answer
then is a larger per-slot cap or a smaller rendering (the `board`
scaffold keeps its frame under a byte budget, SPEC N52), not a change to
this rule.
