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

## Found beside it, and fixed after it (SPEC C22)

At a HARD limit of 40, m0serve 1.16.0 and this change alike spun a core
before the loop started, printed nothing past the banner, and did not stop
on SIGTERM (SIGKILL ended them). A started server holds about 14
descriptors and 4 per pool thread before its first connection: 22 with two
threads, 46 with the auto eight. At 40 the pool was up when the loop's
`kqueue` failed with EMFILE, and `_serve_offloaded` raised past a thread
state it had already given up. The unwind freed the `OffloadPool` under its
threads; one of them, the first to take the GIL, read the freed job ring,
whose sequence numbers a free had scrambled, and spun in the ring's retry
holding the GIL. Main's teardown then waited in `PyGILState_Ensure` for a
GIL nobody would release, and SIGTERM's byte sat in a pipe nothing read.
`sample` showed both: main in `List[WSGIApp].__deinit__` waiting on
`take_gil`, one pool thread at 100 % in `_pool_serve`, the other seven
queued for the GIL.

A loop that raises now exits 1 at once through `_fail`, which is `_exit`
and unwinds nothing, naming the call and its errno: `m0serve: the event
loop raised: kqueue: Too many open files (errno 24)`. The backend's
construction moved inside the `try`, since it is what opens the kqueue; the
first version of the fix wrapped the loop alone, and still spun. `--threads`
loops do the same, and the inline path too, for one rule. The Mojo host
needed nothing: its pool takes no GIL, so its unwind finished and it
already exited 1. `smoke-max-connections` runs sixteen pool threads under a
hard limit of 40 on macOS and wants exit 1 within 15 s, naming the loop;
with the backend moved back above the `try` it was still running at 15 s.
The arm is macOS's because the order is: there `PoolThreads.deal` opens
each thread's wake channel on the spawning thread, before the kqueue. On
Linux no wake channel is opened, and a thread's own descriptors wait for
the GIL that main releases just before it opens epoll, so epoll is served
first and the threads' failures are tolerated; the first CI run of the arm
found the Linux server serving at 15 s. Linux's arm holds a limit of 12,
below what startup holds before the loop, to the same prompt exit.

The limit's notice had a wrong number of its own. It said "a loop will
hold about 0" at 40, from `limit - 256`, though 256 is the headroom asked
for, not what is used, and that server served. The line now says that a
connection past the limit is refused at accept, and no figure.
