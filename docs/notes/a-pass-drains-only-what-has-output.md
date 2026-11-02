# A pass drains only what has output — 2026-11-02

A design note from the engineering record. SPEC C24 is its row. It
extends [the outbox sweep](outbox-sweep.md), which made a pass skip the
drain when nothing streams, to a loop holding many streams that are idle.

## What was found

Every pass of the event loop ended in the outbox drain, `_drain_outboxes`,
and the drain visited every slot holding a stream: it asked the handler
for the slot's pending bytes (`sse_drain_slot`) whether or not the
handler had queued any. A request answered on a loop that holds streams
paid for a visit to each of them. Measured against m0serve on an M4 with
`wrk -t2 -c16` on the health path, which the loop answers itself:

| Held streams | Requests a second | Median |
|---|---|---|
| 0 | 150.6k | 91 µs |
| 1008, the default stream share | 132.1k | 119 µs |
| 4000 | 65.2k | 244 µs |

With 15000 held and one client sending requests in turn, a request's
median rose from 0.035 ms to 0.41 ms, and `sample` put 93% of the loop
thread in the drain: the sweep itself, `WSGIHandler.sse_drain_slot` and
`SSERegistry.drain`. The streams were idle; nothing was sent to them.

The figures are the health path's, and part of the 4000-stream row was
the health answer's own walk (below); the drain's share is the 1008 row,
at the same 1024 slots as the first. `--max-connections` goes to 65536
since #646, and
[a loop keeps slots for requests](a-loop-keeps-slots-for-requests.md)
says more connections than that means more loops. The table says a
few thousand idle streams already did.

An emptiness check in `SSERegistry.drain`, which copied an empty outbox,
was tried first and recovered almost nothing (0.410 ms to 0.372 ms): the
cost was the visit -- the slot's state in a provision a few hundred bytes
from the next, the pool's tables, a call through the handler -- not the
copy. So the fix is to make fewer visits.

## What changed

**The handler names its streams with output, and the loop visits those.**
`HTTPService.take_ready_streams(mut slots) -> Bool`, called once a pass
before the drain, appends every slot whose outbox gained bytes since the
last call, and every slot whose stream ended, and answers True. The
default answers False, and a loop whose handler answers False sweeps
every stream as before, so a handler written for an earlier release is
unchanged. The registries keep the list: `SSERegistry` names each slot
`notify_frame` or `queue_frame` queues for and each it unsubscribes, and
`WSHub`, `Feed` and `DatastarStream` do the same or forward it. m0serve's
`WSGIHandler` forwards both of its registries, and names every stream it
ends with bytes still pending (`_end_once_drained`).

**The loop names a slot whose frame has landed.** A slot still sending is
passed by -- it cannot take another frame -- and what the handler named
for it meanwhile would otherwise wait for the next thing to name it.
`_stream_idle`, the transition every stream takes when a frame finishes on
the write-ready path, names the slot to the next drain. That is also when
a Datastar state stream's catch-up (SPEC I44) needs its drain: the moment
a stalled subscriber has room.

**A slot named while the drain runs is the next drain's.** The drain
walks `drain_now`, swapped with `drain_due` as it begins, so a catch-up
queued by a slot's own drain lands in the fresh list rather than being
cleared with the one walked: next pass, as the sweep sent it.

The per-slot body moved, unchanged, from the sweep into `_drain_slot`,
which both paths run. Under the pump executor the loop keeps sweeping
every pass, since that sweep is its pacing ([the outbox sweep](outbox-sweep.md)).

## Why a list the handler keeps

The loop cannot see a handler's outboxes; something has to tell it which
changed. A list beside each outbox, with a flag per slot so a slot is
named once however many frames it queues, is two stores per frame queued
and nothing per idle stream. The rule it carries is the hook's: a handler
that answers True names from every outbox `sse_drain_slot` drains, or a
stream waits. The default keeps that rule from reaching a handler that
did not opt in. A periodic full sweep behind the list, as a net for a
missed name, was weighed and left out: it turns a missed name into a
delay no gate would see, which is the shape of a lost wakeup that a timer
heals.

## Two more costs that grew with the loop

**m0serve's health answer walked every slot.** Under `--realtime` it
reports its subscribers and sockets, and `SSERegistry.active_count`
counted them by walking every slot, twice a check. At 4096 slots that was
about 5 µs a request, on the path a load balancer polls, and part of what
the table above charged to 4000 streams: the walk is per slot, not per
stream, so it cost the health path at 0 streams too. The registry now
keeps the count as `subscribe` and `unsubscribe` change it, the only two
writers of `is_streaming`.

**A registry was copied at every visit.** Measuring the Mojo host, whose
applications keep the sweep, put the change 4% behind the old tree at
1008 idle streams (140.2k against 146.2k requests a second). The sweep's
code was not it: the old drain built into the new tree measured the same.
It was the visit itself. `SSERegistry` grew from 104 to 160 bytes with
the list, and a `mut self` of 256 bytes or less is copied in and stored
back at a call boundary ([mut arguments](mut-arguments-and-raw-addresses.md)),
so every idle stream's `drain` copied the registry in and out, more of it
than before. With the methods a loop reaches once a stream a pass, or once
a subscriber a frame, `@always_inline` (`drain`, `is_slot_streaming`,
`has_pending`, `mark_ready`; `WSHub`'s and `Feed`'s likewise), the host
went past the old tree: 151.1k against 145.3k. The old tree paid the copy
too, at 104 bytes.

## What it returns

Both trees on an M4, alternating, `wrk -t2 -c16` on the health path, which
m0serve answers on the loop, three runs a row (five at no streams):

| m0serve, held streams | Before | After |
|---|---|---|
| 0 | 158.0k | 225.2k |
| 1008 | 136.7k | 225.1k |
| 4000 (4096 slots) | 66.2k | 223.1k |

With 15000 held and one client sending `/plain` in turn, a path that
counts nothing, a request's median went from 0.366 ms to 0.043 ms (0.035
holding none), 2581 requests a second to 22337. A loop's request rate no
longer depends on how many streams it holds.

The Mojo host's counter, which names nothing and keeps the sweep: 194.9k
and 192.6k at no streams, inside the run's spread; at 1008 idle streams
143.0k before and 149.3k after, the copy gone.

## The gate

The unit tests hold the loop and the four lists, but not m0serve's own
naming: a `WSGIHandler` that named nothing would have every streaming smoke
green, since the sweep it falls back to is correct, only slow. So the
drain counts its visits (`http_stream_drain_visits_total`) and
`smoke-max-connections` reads the count against m0serve:

- 60 idle held streams and 200 ordinary requests beside them: 0 visits,
  where the sweep made at least one a stream a request;
- one publish to the 60: 60 visits, and every stream received it;
- a stream whose client stops reading through fifty 20 KB frames, which
  fill its socket, leave one frame going out and three in its outbox, and
  are refused past the outbox's cap, then a last `data: end`, which fits
  beside the three and finds the slot busy: once the client reads again
  it is sent `end`, with nothing published after. Only the landing of the
  frame that was going out names the slot then.

## Sabotaged

Each rule reverted alone was caught. In the loop, against the two
lifecycle tests: a landed frame not naming its slot; the drain walking the
list it clears; a slot named twice visited twice; the handler's names
ignored; the skip with no stream held firing whatever is held. In m0serve,
against the smokes: a broadcast naming no slot (`smoke-realtime-holds`); a
frame queued for one slot not naming it, and an unsubscribe naming none
(`smoke-wsgi-stream`, whose stream ends with nothing pending); the handler
naming its streams but not its sockets (`smoke-flask-realtime` and
`smoke-django-realtime-ws`, where `smoke-ws-inbound` passed it: its ASGI
executor sweeps every pass); naming nothing (the probe's quiet phase); and
a landed frame not naming its slot (the probe's stalled stream, which
read 480 KB ending in a flush comment, `end` left in its outbox, where
`smoke-outbox-cap` had passed it).

The names `_end_once_drained` adds were not reverted alone: a stream it
ends with bytes pending was named when they were queued, or is named as
its frame lands, so they are a second name, kept for the case nothing
here reaches.

## Left as it is

The Mojo host's handlers are the applications' own, and they keep the
sweep until they wire `take_ready_streams` to their stream; the m0
templates do not yet, and their visit, a few nanoseconds once inlined, is
cheap where their streams are few. The pump executor sweeps every pass, as
before. `subscriber_count(url)`, which the counter's health answer reads,
still walks every slot; it is per url, and an application's to call.
