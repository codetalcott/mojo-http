# A loop keeps slots for requests — 2026-10-29

A design note from the engineering record. SPEC C20 and C21 are its rows;
[Running m0serve](../RUNNING.md#limits-and-lifecycle) states the limits.

## What was found

A skeptical review of m0serve 1.16.0, run from PyPI against its own
quickstart, opened 1100 held SSE streams on one process. 1024 were
answered 200. The other 76 read a TCP reset, and so did `/health` while
the streams were held. The loop's slot pool is 1024, a constant with no
flag, and a connection that finds the pool empty is closed at accept with
its request unread, which the kernel sends as a reset. A held stream keeps
its slot until its client leaves, so a server full of streams refused its
health check, and a load balancer marks it dead at the moment it is
busiest. The front page did not mention the ceiling, and docs/MOJO.md said
the stack suits "thousands of held streams".

The same server started from a terminal on macOS held fewer. launchd's
default soft limit on open descriptors is 256. Under it, 300 holds got 208
answers and 92 resets, and `/health` was reset too. Throughout, the banner
said `max_connections=1024`. The soft limit was the real ceiling, and
nothing said so. systemd's default soft limit is 1024 under a hard limit of
524288, so a unit file without `LimitNOFILE=` meets the same wall a little
higher up.

## What changed

**The count is a flag.** `--max-connections N` (`M0_MAX_CONNECTIONS`) is
the slots one loop holds, 1024 by default and at most 65536. The loop's
periodic sweeps walk every slot, so more connections than that means more
loops (`--workers`, `--threads`); the doctor's `max-connections` rule
refuses more with 78. The handler's per-slot tables, which were sized by a
second constant 1024 (`REALTIME_SLOTS`), are now sized by the same count.
Slots index those tables directly, so a slot the loop could hand out and a
table could not hold was a subscription that silently did not happen.

**Streams leave a reserve.** A loop lets streams take all of its slots but
a sixteenth, at most 16 (`ServerConfig.stream_reserve`). The stream after
that is answered `503` with `Retry-After: 5` and `Connection: close`. The
handler subscribed the slot before the loop saw the head, as a pool
thread's hold sends its subscription first. So the refusal drops it through
`sse_slot_disconnected`, the hook every stream's close calls, which is what
the HEAD case already did. The count of held streams is raised where
`_finish_response` sets a stream flag and lowered by the flag's two resets,
`_close_slot` and `_chunked_stream_ends`, which keeps the C4 rule that
every per-slot reset has one owner. A stream on the chunk channel, from an
executor or a pool thread streaming an iterable, is counted and never
refused. It ends on its own, and its producer is mid-flight.

**The server raises its own descriptor limit**, before the bind and the
fork, to what its connections need. That is each loop's count plus 256 for
the listener, channels, pipes and the application's files. It never lowers
the limit, never goes past the hard limit, and never goes past 2^20, where
epoll's timer idents stop telling descriptors apart (review record LF18).
It raises only to what is needed, not to the hard limit, because a child
process inherits the soft limit. When the hard limit stops it short, one
line names the limit, what was wanted and the fix. The Mojo host does the
same.

## Why 503, and why a reserve rather than refusing at accept

Holding a stream is the one thing that keeps a slot without a deadline.
Ordinary requests cycle through the idle timeout. Capping streams below the
slot count therefore leaves the reserve for what does cycle: health checks,
page loads, publishes. A refusal at accept could answer nothing. It
happens before any byte is read, and with no slot there is nowhere to read
one.

`503` with `Retry-After` is what HTTP says for a server that is up and
cannot take this now. One consequence for pages: a browser's `EventSource`
does not reconnect after a non-200 answer, where it does after a reset. A
page that should keep trying listens for `error` and reconnects itself.
RUNNING.md says so.

## The cost

Reserving slots cuts the default stream capacity from 1024 to 1008.
`--max-connections 1040` holds 1024 streams, as 1.16.0 did. A stream's
begin is one comparison and a counter. Slots are provisioned lazily
(`ConnectionProvision.ensure_buffers`), so a larger count costs memory only
as connections arrive. The per-slot tables and the once-a-second sweep grow
with it.

## Found beside it, not fixed here

At a HARD limit of 40, m0serve 1.16.0 and this change alike spin a core
before the loop starts and print nothing past the banner. The server
needs more descriptors than that to build its pool, and something on that
path retries instead of failing. A hard limit that low is not a real
configuration. It is recorded so that the next server to meet one does
not read it as a new bug.
