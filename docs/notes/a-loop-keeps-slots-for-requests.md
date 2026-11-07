# A loop keeps slots for requests — 2026-10-29

> A design note from the engineering record. SPEC C20 and C21 are its rows,
> and C22, C25 and C26 the sections found after it;
> [Running m0serve](../RUNNING.md#limits-and-lifecycle) states the limits.

Streams may take all of a loop's slots but a reserve, a sixteenth and at
most 16, and the stream after that is answered 503 with `Retry-After`. The
server raises its own descriptor limit to what its connections need. Found
when 1100 held streams on m0serve 1.16.0 left `/health` reading a reset.

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
begin is one comparison and a counter. A connection's buffers are sized
on its slot's first use (`ConnectionProvision.ensure_buffers`), about 8 KB
of resident memory a held stream, but a larger count is not free before
any connection arrives: measured on an M4 on 2026-11-02, m0serve's idle
resident memory was 40 MB at 1024 slots, 92 MB at 16384 and 256 MB at
65536, about 3.35 KB a slot. About 0.9 KB of it is the loop's own tables
and provisions, and the rest was the handler pool's, which now reserves
28 B a slot (SPEC C26, below). The once-a-second sweep grows with the
count too.

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
already exited 1.

That exit is the backstop, not the fix. A gate for it was tried three
ways and each found something. Sixteen pool threads at a hard limit of 40
reached the loop's failure on an M4 every time and on neither CI runner,
where both served: a pool thread's wake and ack channels may fail and are
let go, and they race the loop's kqueue or epoll for the last descriptors.
A sweep from 40 down to 12 then found, in a Linux container, every ODD
limit from 39 to 15 segfaulting and every even one serving. gdb put main
in `fclose(NULL)` under `_serve_offloaded`: the stdlib's `print(flush=
True)` flushes through `fdopen(dup(1))`, and with one descriptor left for
a pair and none for the `dup`, `fdopen` returned NULL, which it closed. On
the x86-64 runner the same limit ended in `LLVM ERROR: IO failure on output
stream`. So a startup under a limit that low fails wherever the last
descriptor goes, and no exit path can be made safe for all of them.

So the server refuses first. `descriptor-floor`, the last of the checks
after the import, the doctor's too, compares the limit as the server
raises it with what the configuration holds before its first connection
plus 16 for connections, and exits 78 naming both and the fix before any
pool exists. The count is the M4's, the larger platform's: 8, and per loop
with a pool or an executor 8 more and 4 a handler thread, 8 for the
executor. In the container every limit from 48 to 12 then exits 78 with
sixteen threads; with two, 48 to 40 serve and 39 down are refused. The
gate holds both shapes on both runners, and the exit that unwinds nothing
stays for an estimate that is wrong, proven by the sabotage above and
reached on purpose by no limit now.

The limit's notice had a wrong number of its own. It said "a loop will
hold about 0" at 40, from `limit - 256`, though 256 is the headroom asked
for, not what is used, and that server served. The line now says that a
connection past the limit is refused at accept, and no figure.

## Found after it: a limit the raise cannot reach (SPEC C25)

Where the hard limit stopped the raise short, the server said so and kept
its count: one line, and a connection past the limit "refused at accept".
But the reserve was taken from the count, not from the limit, so under a
limit that held fewer connections than the count, streams took every
descriptor before they reached the reserve. Under a hard limit of 300 with
two pool threads, 400 holds got 276 answers and 124 resets, and the health
check read an EOF: the case C20 exists for, met one level down. C23's
taking back of idle slots does not reach it either, since the failure is
`accept` itself, out of descriptors, below the slot pool.

So the loop is fitted to the limit (`connections_within`): what the limit
leaves after the server's own descriptors (C22's estimate, at the most the
application's import can make it, since the protocol and so the executor
are learnt after the bind) and a margin for the files the application
opens -- an eighth of what is left, at least 16 and at most 256 -- shared
among the loops. The reserve is then taken from the fitted count. Under
300 a loop holds 242, streams 227 of them, the next 15 are answered 503,
and the health path is answered while they are held. The notice names the
count and the streams' share, and the doctor reports them.

That is macOS. The gate's first run on a Linux runner held 148 of 242: the
epoll backend arms each connection's timer -- a stream's heartbeat, a
body's deadline -- as a timerfd of its own, where kqueue's timers are no
descriptor, so a held stream is two descriptors on Linux. The raise had
counted one a connection since C21, so a server raised to what its
connections "needed" under systemd's soft 1024 would have run out near 640
of its 1008 streams, the failure C21 was written against. Both the raise
and the fit now count `DESCRIPTORS_PER_CONNECTION`, one on macOS and two on
Linux: under 300 a Linux loop holds 121, streams 114 of them.

The raise asks for more than it did: each loop's connections, the server's
own descriptors and the 256 of headroom, where it asked for the connections
and the 256, which the server's own came out of. Eight loops of eight pool
threads hold 328 of their own, so a raise that succeeded could still leave
the connections short. Asked for so, a raise that succeeds fits every
loop's count unchanged.

The same change caps the raise on macOS at `kern.maxfilesperproc`. Darwin
27 accepts a soft limit above it and enforces it anyway: `setrlimit` set
65792 and read it back, and the 61441st `dup` failed with EMFILE. So
`--max-connections 65536` reported a limit of 65792 and no shortfall, where
connections past about 61000 were refused. The raise now answers no more
than the ceiling, from a soft limit below it and from one above (a shell's
`ulimit -n unlimited`), and the fit counts from that.

## Found after it: what the pool reserved per slot (SPEC C26)

The cost above put 2.5 KB of every slot on the handler pool's two job
tables, a request and a response reserved for each slot. Measured
(`scripts/probes/pool_idle_rss.py`, idle resident memory over the counts
the doctor fits, M4, m0serve 1.17.0, 2026-11-07), the pool's share was
2380 B a slot at the default eight threads, and the tables were 752 B of
it: `Optional[HTTPRequest]` is 456 B and `Optional[HTTPResponse]` 296 B.
The share grew with the thread count, 973, 1179, 1579 and 2380 B at one,
two, four and eight threads: 773 B fixed and about 200 B a thread.

The 200 B a thread were stream tables. m0serve sets `asgi_streaming`
whenever there is a pool, since a pool thread streams a WSGI iterable
through the chunk channel to the loop handler's registries, and every
handler built from those options sized its two registries and eleven
per-slot lists by the count, each pool thread's handler included. Nothing
drains a pool thread's registries: a hold it takes travels to the loop's
handler as a frame. A pool thread's handler now sizes them at 0
(`WSGIHandler.make`, `owns_streams`), and a `--threads` serving loop's,
which holds streams, keeps them.

The tables never held more than a few hundred jobs. The loop submits only
while fewer than `OFFLOAD_MAX_INFLIGHT` (256) are in flight, and every
write and read of a slot's request and response falls inside its job's
time in flight: the park before the count goes up, the take, discard or
unpark after it comes down. So the tables now hold 256 entries whatever
the slot count, and a slot keeps the index of its entry. Only the loop
takes an entry, in `park_request`, writing the index before the submit
that publishes the job, the edge that published the request itself; and
only the loop gives one back, at `take_response`, `discard` or
`unpark_request`, after which no thread touches it. Every lookup goes
through the slot's own index, so a write meant for one slot cannot reach
another's job. The loop accepts no job while every entry is held, which
the in-flight count already implies; a count gone wrong then runs the
request inline rather than parking it on another job's entry.

| shape (`--realtime`) | before | after |
| --- | --- | --- |
| no pool | 1113 B a slot | 1117 B a slot |
| eight pool threads | 3493 B a slot | 1145 B a slot |
| the pool's share | 2380 B a slot | 28 B a slot |
| eight threads, 61136 slots | 239.6 MB | 102.7 MB |

An ASGI application on the executor pays its own: 2446 B a slot before,
1697 after, against 916 for WSGI with no pool and no `--realtime`. The
remainder is the executor's per-slot state (`ExecutorState`, whose
`pending_101` is another response a slot) and its handler's stream
tables, which are not this change's.

`smoke-max-connections` measures the share at 1024 and 16384 connections
and fails above 128 B a slot, a bound either cause, brought back, would
exceed many times over.
`poe sabotage-pool` reverts each entry rule, and `test_offload.mojo`
catches every one.
