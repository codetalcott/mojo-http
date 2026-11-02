# A full loop takes back an idle slot — 2026-11-02

A design note from the engineering record. SPEC C23 is its row;
[Running m0serve](../RUNNING.md#limits-and-lifecycle) states the limits.
It follows [a loop keeps slots for requests](a-loop-keeps-slots-for-requests.md),
whose reserve it makes hold.

## What was found

C20 keeps a loop's last slots from streams, so the health path still finds
one while streams hold the rest. Measured against m0serve on an M4 at
1024 slots, three ways of filling a loop that are not streams defeated it.

| The loop held | A new connection, `/health` among them |
|---|---|
| 1008 streams and 16 idle keep-alive connections | closed unread; the next streams were reset, not answered 503 |
| 1024 idle keep-alive connections from one client | reset for 61 s, the 60 s idle timeout |
| 1024 connections that never sent a byte | reset for 11.5 s, the 10 s header timeout |

The first is what browsers do. A tab that holds a stream also loaded the
page and posts through an ordinary connection, which its browser keeps
open between requests, so the reserve fills with the page loads of the
tabs that hold the streams. The second is any HTTP client with a
connection pool, and it renews itself by sending one request per
connection a minute. When `_admit_connection` found no free slot it
closed the new connection with its request unread, which the client
reads as a reset, while slots it could have had sat idle.

## What changed

**A full loop takes a slot back from a connection a deadline is already
counting down, and refuses the new one only when none is.** The idle sweep
closes a connection that stays between requests for `--idle-timeout`, and
the header timeout one whose head takes longer than 10 s. Under pressure
one of those deadlines arrives early, for the slot nearest it:

1. **Between requests, the longest idle first**, closed as the idle sweep
   closes it. RFC 9112 §9.5: "A client, server, or proxy MAY close the
   transport connection at any time", and its example is this one, a
   server closing an idle connection as its client begins a request,
   which §9.3.1's retry rules exist to recover. It is nginx's answer to
   running out of `worker_connections` (`ngx_drain_connections`, which
   closes "reusable" connections).
2. **Then a head still arriving, the oldest first, once it has been
   arriving for a second**, answered as the header timeout answers it: a
   408 to a connection's first request, then the close. RFC 9110
   §15.5.9's 408 tells a client with a request in transit that it MAY
   repeat it, where a bare close tells it nothing. The second is the floor
   that keeps a client that has just connected, and is about to send,
   from being the one taken; a loop whose heads are all younger refuses
   the new connection as before.

The same section says a server SHOULD sustain persistent connections when
possible rather than terminate them expecting clients to retry. On a full
loop that is no longer possible, and the choice is between two closes:
the new connection's, which loses a request its client has just sent, or
an idle one's, which loses nothing in flight and costs its client a
connection the next time it asks.

A stream, a body arriving, a response going out and a request on a pool
thread are never taken. None waits on a deadline that would close it, and
each is a client being served.

The first full loop prints one line naming `--max-connections`.
`/__metrics` counts `http_connections_reclaimed_total` and
`http_connections_refused_total`; before, a connection refused at accept
was counted nowhere, `http_accepts_total` counting only those a slot took.
`M0_RECLAIM=0` keeps the old refusal, an A/B knob and the smoke's negative
arm.

After, at 1024 slots, the same three loops:

| The loop held | A new connection |
|---|---|
| 1008 streams and 16 idle keep-alive connections | answered; the next streams answered 503, as C20 says |
| 1024 idle keep-alive connections | answered at once |
| 1024 silent connections | refused for their first second, then answered |

## How a slot is chosen

Choosing must not walk every slot while new connections wait: a loop may
hold 65536. So the slots that may be taken queue in the order they became
takeable, in two FIFO queues (`lightbug_http/slot_queue.mojo`): between
requests from the moment a response ends (`_end_request`), and with a
head arriving from the moment its first byte did (`_start_head`, through
which every stamp of the header clock now goes: the accept path, the read
path, the pipelined drain). `_close_slot` takes a slot out. The links are
intrusive, one `prev`/`next` pair per slot that both queues share, so a
slot is in at most one and each move is O(1).

The queues know nothing of what makes a slot takeable. A slot whose state
moved on since it joined -- a head framed, a request sent to a pool
thread, a stream begun -- stays where it is until `_reclaim_slot` meets it
at a front, checks it against the predicate for its queue
(`_between_requests`, `_head_arriving`), and drops it. Only the
transitions into a queue and the close touch them, which keeps C4's rule
that each per-slot reset has one owner: queue membership belongs to
`_start_head`, `_end_request` and `_close_slot`. The head queue is in the
order its clocks started, so a front younger than the floor means nothing
behind it is old enough either.

## The cost

Two queue moves per kept-alive request, its head starting and its
response ending. A first version cost the health path 1.5% under `wrk`
(229.4k requests a second against 232.8k, five runs each), and a build
with the two moves removed matched the old tree (232.5k), so the moves were
the cost. Two linked-list moves are a few nanoseconds, not 60: the struct
is five lists, 120 bytes, and a `mut self` of 256 bytes or less is copied
in and stored back at a call boundary
([mut arguments](mut-arguments-and-raw-addresses.md)). Inlined into the
loop's own functions, which hold the state by reference, the moves cost
nothing measurable: 231.5k against the old tree's 231.9k. `/plain`, which
crosses a pool thread, was at parity throughout (207.0k against 206.2k).

A scan at the moment of need was the alternative: no work per request,
O(slots) per reclaim. It loses where it matters, a loop that is full and
still receiving connections, which would pay a walk of every slot for
each one.

## Sabotaged

Each rule reverted alone, with the three lifecycle tests run against it
on an M4 and in a Linux container (arm64, epoll), was caught on both: no reclaim at all; a response's end not queueing the slot; a
head's start not queueing it; no floor; heads taken before idle
connections; a slot counted as a head whenever its clock runs, which
takes streams and bodies; and `M0_RECLAIM` ignored. On the wire the smoke's
negative arm is the first: under `M0_RECLAIM=0` the probe reads a reset
where it otherwise reads 200.

## Left as it is

A loop full of what may not be taken still refuses a new connection at
accept. Leaving it in the listen backlog until a slot frees would turn a
reset into a wait, and on an edge-triggered listener would need the freed
slot to owe the accept a pass; nothing has measured which a client
prefers. The Mojo host prints no notice: it has no `--max-connections` to
name.
