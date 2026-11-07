# A full loop takes back an idle slot — 2026-11-02

> A design note from the engineering record. SPEC C23 is its row;
> [Running m0serve](../RUNNING.md#limits-and-lifecycle) states the limits.
> It follows [a loop keeps slots for requests](a-loop-keeps-slots-for-requests.md),
> whose reserve it makes hold.

A loop with every slot in use takes one back for a new connection from a
connection whose deadline is already counting down: first the connection
longest idle between requests, then the oldest head still arriving, each
once it has waited a second. The new connection is refused only when no
slot qualifies.

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

1. **Between requests, the longest idle first, once it has been idle for
   a second**, closed as the idle sweep closes it. RFC 9112 §9.5: "A
   client, server, or proxy MAY close the transport connection at any
   time", and its example is this one, a server closing an idle
   connection as its client begins a request, which §9.3.1's retry rules
   exist to recover. It is nginx's answer to running out of
   `worker_connections` (`ngx_drain_connections`, which closes "reusable"
   connections). The floor came a day later, from a review
   ([below](#the-idle-floor)).
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
an idle one's, which costs its client a connection the next time it asks
and loses nothing in flight, provided the connection really is idle: a
second without a request, not a moment.

Neither queue is taken from while its timeout is off. With
`--idle-timeout 0` the idle sweep never closes a connection between
requests, and with a header timeout of 0 (a Mojo host application's
`ServerConfig`) nothing closes a slow head; no deadline is counting
either down, so a full loop takes neither and refuses the new
connection.

A stream, a body arriving, a response going out and a request on a pool
thread are never taken. None waits on a deadline that would close it, and
each is a client being served.

The first full loop prints one line saying what this configuration takes
back, or that it refuses each new connection under `M0_RECLAIM=0` or with
both timeouts off, and naming `--max-connections`.
`/__metrics` counts `http_connections_reclaimed_total` and
`http_connections_refused_total`; before, a connection refused at accept
was counted nowhere, `http_accepts_total` counting only those a slot took.
`M0_RECLAIM=0` keeps the old refusal, an A/B knob and the smoke's negative
arm.

After, at 1024 slots, the same three loops:

| The loop held | A new connection |
|---|---|
| 1008 streams and 16 idle keep-alive connections | answered; the next streams answered 503, as C20 says |
| 1024 idle keep-alive connections | answered at once, once they have been idle a second |
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

## The idle floor

An ultrareview of the change, the day it merged, found the first queue
taken with no floor. `_between_requests` asks what the loop has read: a
slot answered, with nothing of the next request read or buffered. It
cannot see a request waiting in the socket. So with more busy keep-alive
clients than slots, each asking again as soon as it is answered, every
new connection closed the busy connection answered longest ago --
microseconds ago -- over its next request. The close reset that client
and lost the request, a POST among them, which no client may repeat on
its own; the client reconnected and evicted another the same way. Before
C23 only the newcomer was refused, and the clients being served kept
being served.

A connection now has to have been idle for `RECLAIM_IDLE_FLOOR_NS`, a
second, the head queue's floor. The idle time is read off the idle
deadline, which `_end_request` arms at `--idle-timeout` from the moment
the slot joins the queue: no clock read or field is added per request,
the queue stays in deadline order, and a front too young means nothing
behind it is old enough, so the choice is still O(1). A connection idle
for a second can still send its next request as the close lands; that is
the idle sweep's race, at any idle timeout, and the one §9.3.1 recovers.
Under more busy clients than slots, none is ever idle a second: the
newcomers are refused, as before C23, and no busy client loses a request.
The browser shape and the idle pools C23 was built for sit idle for
seconds between requests, and are taken as before.

The smoke's third phase is that load: 64 clients each asking `/plain` in
a loop on a 64-slot loop, and new connections every 20 ms for 1.5 s.
Every newcomer must be refused and no client may lose a request; with the
floor removed the first newcomer evicts a busy client and the phase
fails.

The same review found three smaller things, fixed with it: the queues
were taken from with their timeouts off; the notice said an idle
connection "is closed to admit the next" under `M0_RECLAIM=0`, which
refuses every one; and the probe's keep-alive read spun on an early EOF
where it should have failed. A reclaimed head's 408 is sent and the
socket closed at once, which can turn the 408 into a reset if the rest of
the head is unread; the header timeout's close has always done that, and
it is left for its own change (#660).

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

The idle floor's rules, each reverted alone on an M4: no idle floor
(caught by the order test and the busy-connection test, and on the wire
by the probe's first refusal; run alone, the busy-client phase failed on
its first newcomer, a client losing its second request); the idle queue
taken with its timeout off, and the head queue with its (each caught by
the timeouts test, the first on the wire by the `--idle-timeout 0` arm);
and the notice ignoring `M0_RECLAIM`, the idle timeout or the header
timeout (each caught by `test_cli`, the first on the wire by the smoke's
grep of the `M0_RECLAIM=0` server's log).

## Left as it is

A loop full of what may not be taken still refuses a new connection at
accept. Leaving it in the listen backlog until a slot frees would turn a
reset into a wait, and on an edge-triggered listener would need the freed
slot to owe the accept a pass; nothing has measured which a client
prefers. The Mojo host printed no notice until it had a
`--max-connections` to name; since #658 it says the same line under its
own name (SPEC E43).
