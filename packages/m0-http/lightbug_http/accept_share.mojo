"""Sharing a listener's accepts between prefork workers (SPEC E16).

`--workers N` has every worker wait on the ONE listener the supervisor
bound, and whichever worker wakes first drains the backlog: on macOS the
same worker won 32 of 32 keep-alive connections in a burst, on Linux
23–31 of 32, forked or spawned alike (docs/notes/accept-sharing.md). A
keep-alive load then runs at that one worker's throughput. Wakeup tweaks
do not move it — the loop re-enters its wait in microseconds and wins the
next race before a sibling is scheduled — and the kernel offers nothing
portable: `SO_REUSEPORT` hashes across listeners on Linux and sends every
connection to the last-bound socket on macOS (measured, 64 of 64).

So the worker that won the accept gives the connection away. Every accept
asks `pick`, which reads each sibling's load off the pre-fork shared page
and names the least loaded (ties rotate); a connection for a sibling is
passed as an open descriptor over that sibling's `AF_UNIX` channel
(`c/fdpass.mojo`, `SCM_RIGHTS`), and the loop that drains the channel
admits it exactly as it would one it accepted itself — same slot, same
eager read, same everything. The acceptor closes its own reference. Cost:
one `sendmsg` and one `recvmsg` per connection that changes hands, and
nothing at all with one worker (`active()` is false, and every entry
point is a Bool check away from being skipped).

A worker's words sit on its own cache line of the shared page, so the
per-pass stores contend with nothing. Three are the load it advertises,
and a fourth is its own bookkeeping:

- `state`: `STATE_NOT_STARTED` (0, what a fresh page holds) until its
  loop starts, `STATE_PARKED` while parked in its wait, the pass's start
  time (ns) while it is inside one, `STATE_LEFT` once it is shutting
  down. A sibling inside a pass for longer than `ACCEPT_SHARE_BUSY_NS` is
  skipped — that is a worker running a slow view inline, and handing it a
  connection would queue the client behind that view where the old race,
  for all its unfairness, would have sent it to the idle worker. A worker
  mid-pass for a few microseconds is fine to send to.
- `active`: its open connections, published at the bottom of every pass.
- `pending`: connections passed to it that it has not yet admitted —
  incremented by the sender before its `sendmsg` (and taken back if the
  send fails), decremented by the receiver at the end of the pass that
  admitted them. Without it an acceptor draining a burst sees a sibling's
  stale count of zero thirty-two times over and hands it everything.
- `taken`: of those, the ones it has received and not yet retired from
  `pending`, written as it receives each and zeroed as it retires them. A
  worker that dies between the two leaves here the count of connections
  that died with it, which nothing else would take back from `pending`,
  and the worker that takes its index subtracts it (`start`).

What can never happen: a lost connection. A send that fails for any
reason (the sibling's channel full, a sibling gone) keeps the connection
where it is; a datagram queued to a worker that crashed waits in the
channel for the respawn, which inherits the same fd by index and drains
it at its first pass (one that is not respawned is the exception, below:
"A worker that DIES").

The kernel is the other party that could lose one. On macOS a connection
in flight whose sender has closed its copy, which every hand-off is, was
flushed by the collector of descriptors in flight whenever it ran: its
request discarded, its receive side shut, so the receiver read EOF and
closed it unanswered. Any AF_UNIX socket closed on the machine schedules a
run. Each channel's read end is kept in flight for the life of the
process (`_anchor_channels`), which makes the collector reach what the
channel holds.

A worker that LEAVES is the case a check of `state` cannot settle alone:
the sender reads the word and then sends, the leaver stores `STATE_LEFT`
and then drains its channel, and nothing ordered the send before the
leaver's last drain. Draining once more as the shutdown began did not
close it. With the gap between `pick` and the send widened in a Linux
container, a sibling's `sendmsg` succeeded 255 ms after the idle leaver
had exited, into a channel nothing would read again: no respawn follows a
clean exit. The client got nothing until the whole server stopped (review
record B25). A handshake on the page closes it, each side writing its own
word before it reads the other's:

- the sender raises the target's `pending`, then reads its `state` again.
  If the target has left, the sender takes the count back and keeps the
  connection (`send_with`), the rule for any send that fails;
- the leaver stores `STATE_LEFT`, then its drain runs until `pending`,
  less what it has received, is 0 (`awaiting_handoffs`), within the
  drain's budget.

Every access is sequentially consistent, so one of the two reads sees the
other side's write: the sender sees `STATE_LEFT` and never sends, or the
leaver sees the count and waits for the datagram it stands for.

A worker that has left also does not admit what its channel delivers. It
passes each connection on to a sibling that has not left, by the same
`send` (`forward`), because its drain closes a connection whose first
byte has not arrived as idle: 1.6 ms after it was received, in the same
container, and the client read EOF (B25's other shape). Only when no
sibling is left, because the whole server is stopping, is the connection
admitted, and the drain treats it as its own. Each hop is to a worker
that had not left, and a worker leaves once, so a connection moves at
most `workers - 1` times.

A worker that has not STARTED is refused as one that has left is. Until
its loop's `start()` nothing reads its channel, and in m0serve that comes
after the application's import, seconds for a Django project. Its words
used to read 0 until then, which `pick` took for parked with no load: a
connection handed to it waited out the startup, and died with it when a
stop reached it before it had armed its handler (review record AR, from
S1). Measured with worker 1 held 3 s before its start, 8 of a burst of 16
went to it and each was answered 3.0 s late; with a SIGTERM 0.5 s into the
hold, all 8 were closed unanswered while the server exited 0. So 0 is
`STATE_NOT_STARTED`, which a fresh page holds from before the fork with
nothing written, and a parked worker writes a word of its own.

A worker that DIES writes nothing more, so the supervisor writes for it:
as it reaps a worker, on every path and whether or not a replacement
follows, it marks the index left (`mark_reaped`, from the page it made
before the fork). Until then a sibling reads what the dead worker last
wrote: a pass, which is busy and skipped once `ACCEPT_SHARE_BUSY_NS` has
passed (a view that crashes dies inside one), or parked, if it was killed
while waiting, which `pick` took for idle. A worker that no replacement
followed -- the supervisor stopping, out of respawns, or the worker
having exited 0 or 78 -- was handed about half of every burst after its
death, each into a channel nothing would read again (review record RP).
What was sent before the mark waits in the channel: for the replacement
when one follows, admitted at its first pass. When the supervisor gives
up on the index instead (out of respawns), it takes each one off the
channel and closes it (`close_reaped_handoffs`), so its client reads a
close at once rather than waiting, unanswered, until the server stops
(review record RB); the connections the dead worker held are lost with
it. The window is the supervisor's own reaction: it reaps in a blocking
`waitpid`; under `--reload` the poll interval bounds it.

A replacement -- a respawn, or a reload's new worker -- takes its
predecessor's index, and with it the channel, `pending` and `taken`,
which `start` accounts for. It marks the index not started as it binds,
its first act after the fork, before any import, over the supervisor's
mark, because nothing reads the channel until the replacement's
`start()`. `send` itself does not refuse a worker that has not started:
a hand-off there is late, never lost while the worker lives, and the
choice is `pick`'s.

Page layout, in Int64 slots of the `SharedAtomics` page `m0serve` creates
pre-fork: slot 0 is the SSE event id (not ours), slot 1 the rotation
counter, slot 2 the page's magic word (`SHARED_PAGE_MAGIC`, not ours
either), and worker `i`'s line starts at slot `8 + 8 * i`. A spawned
worker maps the page by fd with the same slot count.
"""

from std.atomic import Atomic
from std.os import getenv
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns, sleep

from lightbug_http.c.fdpass import (
    send_fd, recv_fd, RECV_FD_EMPTY, RECV_FD_REFUSED,
)
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.pipe import close_fd
from lightbug_http.c.socket import setsockopt, SocketOption, SOL_SOCKET
from lightbug_http.c.socketpair import socketpair_dgram


comptime ACCEPT_SHARE_RR_SLOT = 1
"""The rotation counter: where `pick` starts its scan, so equal loads take
turns rather than the lowest index taking every tie."""
comptime SHARED_PAGE_MAGIC_SLOT = 2
"""Where `m0serve` writes `SHARED_PAGE_MAGIC` on the page it creates."""
comptime SHARED_PAGE_MAGIC: Int = 0x6D30706167650001
"""`m0page` and a version byte, in slot `SHARED_PAGE_MAGIC_SLOT`.

How a process that was handed the page -- as `M0_SHARED_ID_FD` or as the
raw `M0_SHARED_ID_ADDR` -- tells it from whatever else it could be (#322).
Both names survive `exec` as text while the mapping does not, so a child
process that inherited the environment held an address in its parent's
memory and a descriptor number anything may since have reused: `m0pub`
took an id at that address, and the child either died with SIGSEGV or
incremented eight bytes of its own memory and published the result as an
event id. `m0pub` (both copies) checks this word before its first
fetch-and-add and spells the same constant; change one, change all
three."""
comptime ACCEPT_SHARE_FIRST_WORKER_SLOT = 8
"""Worker 0's line begins here — the second 64-byte line of the page."""
comptime ACCEPT_SHARE_WORKER_STRIDE = 8
"""Slots per worker: one cache line each, four of the eight used."""
comptime _WORD_STATE = 0
comptime _WORD_ACTIVE = 1
comptime _WORD_PENDING = 2
comptime _WORD_TAKEN = 3

comptime ACCEPT_SHARE_BUSY_NS: Int = 2_000_000
"""A sibling inside one pass for longer than this is running something
slow inline and is not handed a connection."""
comptime STATE_LEFT: Int = -1
"""A `state` word meaning the worker is shutting down, or is gone (the
supervisor's `mark_reaped`): never send to it."""
comptime STATE_NOT_STARTED: Int = 0
"""A `state` word meaning the worker's loop has not started: never pick it.

Zero, so a fresh page holds it for every worker before the fork with
nothing written; `bind` writes it again for a replacement, and `start`
replaces it with `STATE_PARKED`."""
comptime STATE_PARKED: Int = -2
"""A `state` word meaning the worker is parked in its wait: willing."""
comptime _ANY_LOAD: Int = 1 << 62
"""An own load every sibling's is below: `pick_for_leaver`'s, whose own
line is never a place for the connection."""
comptime _CHANNEL_BUF = 65536
"""Send and receive buffer for a worker's channel. A passed descriptor's
datagram is under a hundred bytes, so this holds hundreds of connections
in flight to one worker; past that the acceptor keeps them."""


def accept_share_slots(workers: Int) -> Int:
    """How many Int64 slots the shared page needs for `workers` workers."""
    return ACCEPT_SHARE_FIRST_WORKER_SLOT + ACCEPT_SHARE_WORKER_STRIDE * workers


def accept_sharing_wanted(workers: Int) -> Bool:
    """Whether `workers` workers share accepts: two or more, unless
    `M0_ACCEPT_SHARE=0` asks for the bare race (the A/B knob)."""
    return workers > 1 and getenv("M0_ACCEPT_SHARE", "") != "0"


def _atomic(addr: Int) -> Pointer[Atomic[Int64], MutUntrackedOrigin]:
    return Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )


def _load(addr: Int) -> Int:
    return Int(_atomic(addr)[].load())


def _store(addr: Int, value: Int):
    _atomic(addr)[].store(Int64(value))


def _fetch_add(addr: Int, delta: Int) -> Int:
    return Int(_atomic(addr)[].fetch_add(Int64(delta)))


def _word_at(page: Int, worker: Int, which: Int) -> Int:
    """The address of word `which` of worker `worker`'s line on `page`."""
    return page + 8 * (
        ACCEPT_SHARE_FIRST_WORKER_SLOT
        + ACCEPT_SHARE_WORKER_STRIDE * worker + which
    )


def mark_reaped(page: Int, worker: Int):
    """The supervisor's store for a worker it has reaped: `STATE_LEFT` in
    that worker's `state` word on `page`, the page's address in the
    supervisor (review record RP).

    Nothing else writes the word of a worker that died: siblings read what
    it last wrote, and a worker killed while parked read as parked with no
    load, so `pick` handed it about half of every burst -- into a channel
    nothing would read again when no replacement followed (the supervisor
    stopping, out of respawns, or the worker exiting 0 or 78). Measured
    with `--workers 2` and worker 1 killed until the supervisor stopped
    respawning it: 16 of a burst of 32 were accepted and never answered.

    Left, not not-started, because `send_with` reads the word again after
    it raises `pending` and refuses only a target that has left: a sender
    that picked the worker before this store and reads it after keeps the
    connection. `pick` and `pick_for_leaver` refuse both. A replacement
    writes `STATE_NOT_STARTED` over this in `bind`, its first act after a
    fork the supervisor makes after this store. Harmless on a line nobody
    reads: accept sharing inactive, or a worker that had left already.
    """
    if page == 0 or worker < 0:
        return
    _store(_word_at(page, worker, _WORD_STATE), STATE_LEFT)


def close_reaped_handoffs(
    page: Int, worker: Int, channel: Int, bound_ns: Int
) -> Int:
    """The supervisor's drain of a worker it reaped and gave up on: take
    every connection off that worker's channel, `channel` in the
    supervisor, and close it, so each client reads a close at once and can
    retry. Returns how many were closed (review record RB).

    What was handed to the worker before `mark_reaped` waits in its
    channel, and nothing reads the channel once no replacement follows:
    each client held an accepted connection that was never answered until
    the whole server stopped. The supervisor's copy of the read end is not
    the last (every sibling holds one, and on macOS so does the anchor,
    `_anchor_channels`), so closing it would release nothing; receiving
    each descriptor and closing it does.

    The leaver's handshake closes the race with a sender that picked the
    worker before the mark (the module docstring): the mark is stored
    first, and the drain runs on while `pending`, less what the dead worker
    had taken (`taken`) and what this drain has received, is above 0, a
    sender having raised `pending` before it read `state` again. A count
    the dead worker left high (it died between a receive and publishing
    `taken`) holds the drain to `bound_ns`, once. What it took and what
    the dead worker had taken are then retired from `pending`, as `start`
    retires the second, so a worker a reload later forks into the index is
    not read as busier than it is, nor waits in its own drain for
    hand-offs that will never come. The connections are closed, not
    passed to a sibling: none was ever read, so a client that retries
    loses nothing.
    """
    if page == 0 or worker < 0 or channel < 0:
        return 0
    var pending = _word_at(page, worker, _WORD_PENDING)
    var taken = _word_at(page, worker, _WORD_TAKEN)
    var received = 0
    var closed = 0
    var until = perf_counter_ns() + bound_ns
    while True:
        var payload = List[UInt8]()
        var fd = recv_fd(channel, payload)
        if fd != RECV_FD_EMPTY:
            received += 1
            if fd >= 0:
                close_fd(fd)
                closed += 1
            continue
        if _load(pending) - _load(taken) - received <= 0:
            break
        if perf_counter_ns() >= until:
            break
        sleep(0.001)
    var dead_took = _load(taken)
    _store(taken, 0)
    var retire = dead_took + received
    if retire > 0:
        var before = _fetch_add(pending, -retire)
        if before - retire < 0:
            _store(pending, 0)
    return closed


trait HandoffPost:
    """How `AcceptShare.send_with` queues a connection on a sibling's
    channel. The server's is `SendFdPost`; a test's own conformance takes
    the receiver's turn inside the hand-off, which no interleaving of real
    processes does on demand."""

    def post(mut self, channel: Int, fd: Int, payload: List[UInt8]) -> Bool:
        """Queue `fd` with `payload` on the send end `channel`: True once
        queued, False when nothing was."""
        ...


struct SendFdPost(HandoffPost):
    """The hand-off itself: one `sendmsg` carrying the descriptor."""

    def __init__(out self):
        pass

    def post(mut self, channel: Int, fd: Int, payload: List[UInt8]) -> Bool:
        return send_fd(channel, fd, payload)


struct AcceptShare(Copyable, Movable):
    """One receive channel per worker, every worker holding every send end,
    plus this worker's view of the shared load page.

    Create **before** `fork_all()` with the worker count (the channels are
    inherited across the fork, or across an exec by fd number under
    `--spawn-workers`), then `bind` in each worker with its index and the
    page address. The default-constructed value is inactive and is what a
    single-worker or threaded server passes.
    """

    var worker: Int
    """This worker's index; -1 until `bind`, which is also "inactive"."""
    var read_fds: List[Int]
    var write_fds: List[Int]
    var page: Int
    """Address of the shared page's slot 0; 0 until `bind`."""
    var left: Bool
    """Set by `leave`: the per-pass stores stop, so the shutdown drain's
    passes cannot un-announce the departure."""
    var drained: Int
    """Connections admitted from the channel since the last `pass_end`."""
    var handoffs_out: Int
    """Connections this worker accepted and gave away, for the record."""
    var handoffs_in: Int
    """Connections this worker received from a sibling, for the record."""
    var handoffs_forwarded: Int
    """Of `handoffs_out`, those passed on after `leave` (`forward`)."""
    var anchor_fds: List[Int]
    """On macOS, the pair whose buffer holds every channel's read end in
    flight for the life of the process (`_anchor_channels`); empty
    elsewhere."""

    def __init__(out self):
        self.worker = -1
        self.read_fds = List[Int]()
        self.write_fds = List[Int]()
        self.page = 0
        self.left = False
        self.drained = 0
        self.handoffs_out = 0
        self.handoffs_in = 0
        self.handoffs_forwarded = 0
        self.anchor_fds = List[Int]()

    def __init__(out self, workers: Int) raises:
        """Create the channels for `workers` workers, pre-fork."""
        self = Self()
        for _ in range(workers):
            var pair = socketpair_dgram()
            set_nonblocking(FileDescriptor(pair[0]))
            set_nonblocking(FileDescriptor(pair[1]))
            setsockopt(
                FileDescriptor(pair[1]), Int32(SOL_SOCKET),
                SocketOption.SO_SNDBUF.value, Int32(_CHANNEL_BUF),
            )
            setsockopt(
                FileDescriptor(pair[0]), Int32(SOL_SOCKET),
                SocketOption.SO_RCVBUF.value, Int32(_CHANNEL_BUF),
            )
            self.read_fds.append(pair[0])
            self.write_fds.append(pair[1])
        comptime if CompilationTarget.is_macos():
            self._anchor_channels()

    def _anchor_channels(mut self) raises:
        """On macOS, put every channel's read end in flight, in the buffer of
        a pair of its own that is never read, for the life of the process
        (review record B25).

        A connection whose sender has closed its copy is held by the message
        in flight alone until the receiver takes it off the channel, and the
        kernel collects descriptors in flight that nothing reaches. XNU's
        collector (`unp_gc`, bsd/kern/uipc_usrreq.c) walks only the list of
        descriptors in flight: it marks the ones still open somewhere as
        reachable and follows what their buffers hold. A channel that is
        merely open is not on that list, so nothing it held was ever
        reached, and every run of the collector flushed it: the receive side
        shut, what the client had sent discarded. The receiver then read EOF
        and closed the connection unanswered. Any AF_UNIX socket closed on
        the machine, by any process, schedules a run: with another process
        doing nothing else, all 200 of 200 hand-offs left in flight 5 ms
        were flushed, and with this anchor none were.

        Held here, each read end is in flight and open at once, so every run
        marks it and reaches what its buffer holds. Linux's collector takes
        only a socket whose every reference is in flight, which an open
        channel never is, and measured nothing there. The pair is
        close-on-exec (SPEC G16) and a spawned worker's exec does not keep
        it, and needs not to: the process that made the channels holds it,
        and the read ends in flight in it are the open files the worker
        adopts by number. Raises if a read end cannot be anchored: 342
        fitted in the 64 KB buffers, measured, so a worker count that runs
        out is far past any a machine serves.
        """
        var pair = socketpair_dgram()
        setsockopt(
            FileDescriptor(pair[1]), Int32(SOL_SOCKET),
            SocketOption.SO_SNDBUF.value, Int32(_CHANNEL_BUF),
        )
        setsockopt(
            FileDescriptor(pair[0]), Int32(SOL_SOCKET),
            SocketOption.SO_RCVBUF.value, Int32(_CHANNEL_BUF),
        )
        self.anchor_fds.append(pair[0])
        self.anchor_fds.append(pair[1])
        for i in range(len(self.read_fds)):
            if not send_fd(pair[1], self.read_fds[i], List[UInt8]()):
                raise Error(
                    "accept sharing: the channel of worker ", i,
                    " could not be anchored",
                )

    def __init__(out self, *, read_fds: List[Int], write_fds: List[Int]):
        """Adopt channels another process image created (`--spawn-workers`)."""
        self = Self()
        self.read_fds = read_fds.copy()
        self.write_fds = write_fds.copy()

    def workers(self) -> Int:
        return len(self.read_fds)

    def bind(mut self, worker: Int, page: Int):
        """Make this the view of worker `worker`, over the page at `page`,
        and mark the worker not started until its loop's `start()`.

        A fresh page reads `STATE_NOT_STARTED` already. A replacement's
        does not: its predecessor's `state` says what that worker last did,
        parked perhaps, while nothing reads the channel until this worker's
        `start()`, which in m0serve follows the application's import. So the
        mark is written here, the first thing a worker does after the fork
        (the module docstring says what a sibling reads before it). Only
        `state`: `pending` and `taken` are the predecessor's in-flight
        hand-offs, which `start` accounts for.
        """
        self.worker = worker
        self.page = page
        if self.active():
            _store(self._word(worker, _WORD_STATE), STATE_NOT_STARTED)

    def active(self) -> Bool:
        """Whether accepts are shared at all: two or more workers, bound."""
        return (
            self.worker >= 0 and self.worker < self.workers()
            and self.workers() > 1 and self.page != 0
        )

    def read_fd(self) -> Int:
        """This worker's channel, for the loop to register; -1 if inactive."""
        if not self.active():
            return -1
        return self.read_fds[self.worker]

    def _word(self, worker: Int, which: Int) -> Int:
        return _word_at(self.page, worker, which)

    def start(self):
        """At loop start: this worker is parked with no connections, and
        siblings may pick it from here on (until now it read
        `STATE_NOT_STARTED`).

        `pending` is deliberately NOT reset — a respawned worker inherits
        its predecessor's channel, and the datagrams queued there are
        connections it will admit and account for at its first pass.

        What the predecessor had taken off that channel and not yet retired
        (`taken`) IS taken back: those connections died with it, and left in
        `pending` they would count against this worker in every `pick` and
        hold its drain to the budget waiting for them (`awaiting_handoffs`).
        Under `--reload`, whose deadline for a drain is the drain's own
        budget, that would end each reload of the index in SIGKILL, which
        leaves the count behind again. `taken` is zeroed first: a death between the
        two leaves `pending` high, never low.
        """
        if not self.active():
            return
        _store(self._word(self.worker, _WORD_STATE), STATE_PARKED)
        _store(self._word(self.worker, _WORD_ACTIVE), 0)
        var taken = _load(self._word(self.worker, _WORD_TAKEN))
        if taken > 0:
            _store(self._word(self.worker, _WORD_TAKEN), 0)
            _ = _fetch_add(self._word(self.worker, _WORD_PENDING), -taken)

    def pass_begin(mut self, now: Int):
        """The loop is inside a pass that started at `now` (ns)."""
        if self.left or not self.active():
            return
        _store(self._word(self.worker, _WORD_STATE), now if now > 0 else 1)

    def pass_end(mut self, active: Int):
        """The pass is over: publish the connection count, retire what the
        channel delivered during it from `pending`, and park."""
        if not self.active():
            return
        var me = self.worker
        _store(self._word(me, _WORD_ACTIVE), active)
        if self.drained > 0:
            # `taken` first, as in `start`: a death between the two leaves
            # `pending` high, never low.
            _store(self._word(me, _WORD_TAKEN), 0)
            var before = _fetch_add(self._word(me, _WORD_PENDING), -self.drained)
            if before - self.drained < 0:
                # A floor, and one that no longer fires: the sender raises
                # the count before its datagram exists (`send_with`), and a
                # predecessor that died between receiving and retiring left
                # it high, never low. It fired when the sender raised the
                # count AFTER its `sendmsg` -- and turned a retire that beat
                # the increment into a count one high for good (R5).
                _store(self._word(me, _WORD_PENDING), 0)
            self.drained = 0
        if not self.left:
            _store(self._word(me, _WORD_STATE), STATE_PARKED)

    def leave(mut self):
        """Shutting down: siblings must stop sending here.

        The leaver's write in the handshake (the module docstring): stored
        before the drain reads `pending` (`awaiting_handoffs`), and never
        undone by the drain's own passes (`left`).
        """
        if not self.active():
            return
        self.left = True
        _store(self._word(self.worker, _WORD_STATE), STATE_LEFT)

    def awaiting_handoffs(self) -> Bool:
        """After `leave`: whether a hand-off a sibling has counted to this
        worker has not reached it yet, which is `pending` less what this
        pass has received (`drained`, not yet retired) above 0.

        The leaver's read in the handshake (review record B25). `leave`
        stored `STATE_LEFT` before this reads `pending`, and a sender raises
        `pending` before it reads `state` again (`send_with`), so a sender
        that missed the leave is counted here, and the drain runs on until
        its datagram is off the channel, or its send failed and took the
        count back. The drain used to end as soon as nothing was in flight,
        and a hand-off sent after that was never read.

        It reads the word the two ordering rules already keep: raised by the
        sender before its datagram exists (R5), retired by the receiver only
        once it has taken the datagram (at the end of that pass, or of the
        drain for what the shutdown took before its first pass), so it is
        never below what is in flight. It can be above: a predecessor that
        died between taking a hand-off and retiring it left the count high,
        which `start` takes back from what it published in `taken`. A death
        in the instructions between a receive and that publication is the
        remainder, and it holds this worker's drain to its budget, which is
        what bounds the wait. False when sharing is inactive or this worker
        has not left.
        """
        if not self.left or not self.active():
            return False
        return _load(self._word(self.worker, _WORD_PENDING)) - self.drained > 0

    def load_of(self, worker: Int) -> Int:
        """A worker's advertised load: open connections plus those in
        flight to it. For the record and the tests; `pick` reads the
        words directly."""
        return (
            _load(self._word(worker, _WORD_ACTIVE))
            + _load(self._word(worker, _WORD_PENDING))
        )

    def pick(self, own_active: Int, now: Int) -> Int:
        """Which worker should take the connection just accepted: this
        one (`self.worker`) or the least-loaded willing sibling.

        `own_active` is the acceptor's live connection count (its own
        published word may be a pass stale). Ties go to whoever the
        rotating scan reaches first, and a sibling that is parked, or
        inside a pass for under `ACCEPT_SHARE_BUSY_NS`, is willing. One
        that has not started its loop, or has left, never is.
        """
        if not self.active():
            return self.worker
        return self._least_loaded(
            own_active + _load(self._word(self.worker, _WORD_PENDING)),
            now,
            take_busy=False,
        )

    def pick_for_leaver(self, now: Int) -> Int:
        """Where a worker that has left passes on a connection its channel
        delivered: the least-loaded sibling that has not left, or this
        worker when none is, because the whole server is stopping.

        Unlike `pick`, this worker's own load never wins, and a sibling
        inside a long pass is taken when every sibling that has not left
        is: it will answer the connection once its slow view is done, and
        the alternative is this worker's drain, which closes a connection
        whose first byte has not arrived (review record B25). A sibling
        that has not started is never taken: the stop that made this
        worker leave may kill it before it arms, and the connection with
        it, where this worker's drain answers what it admits.
        """
        if not self.active():
            return self.worker
        var target = self._least_loaded(_ANY_LOAD, now, take_busy=False)
        if target == self.worker:
            target = self._least_loaded(_ANY_LOAD, now, take_busy=True)
        return target

    def _least_loaded(self, own_load: Int, now: Int, take_busy: Bool) -> Int:
        """The sibling with the least `active + pending` below `own_load`,
        or this worker when none is below it. The scan starts at the
        rotation counter, so equal loads take turns. A sibling that has
        left or has not started is never taken, and one inside a pass for
        longer than `ACCEPT_SHARE_BUSY_NS` only when `take_busy`."""
        var n = self.workers()
        var me = self.worker
        var start = _fetch_add(self.page + 8 * ACCEPT_SHARE_RR_SLOT, 1) % n
        var best = me
        var best_load = own_load
        for k in range(n):
            var i = (start + k) % n
            if i == me:
                continue
            var state = _load(self._word(i, _WORD_STATE))
            if state == STATE_LEFT or state == STATE_NOT_STARTED:
                continue
            if not take_busy and state > 0 and now - state > ACCEPT_SHARE_BUSY_NS:
                continue
            var load = (
                _load(self._word(i, _WORD_ACTIVE))
                + _load(self._word(i, _WORD_PENDING))
            )
            if load < best_load:
                best = i
                best_load = load
        return best

    def send(mut self, target: Int, fd: Int, host: String, port: Int) -> Bool:
        """Pass the accepted `fd` to worker `target` with its peer address.

        True once the datagram is queued — the caller then closes its own
        `fd`. False leaves the caller owning the connection: the target has
        left since it was picked, its channel is full, or the send failed
        some other way.
        """
        var post = SendFdPost()
        return self.send_with(post, target, fd, host, port)

    def forward(mut self, fd: Int, host: String, port: Int, now: Int) -> Bool:
        """After `leave`: pass on a connection this worker's channel
        delivered, to `pick_for_leaver`'s sibling, by `send`.

        True once it is queued there, and the caller closes its own `fd`.
        False when no sibling is left or the send failed: the caller admits
        the connection, the rule for any send that fails (review B25).
        """
        var target = self.pick_for_leaver(now)
        if target == self.worker or not self.send(target, fd, host, port):
            return False
        self.handoffs_forwarded += 1
        return True

    def send_with[P: HandoffPost](
        mut self, mut post: P, target: Int, fd: Int, host: String, port: Int
    ) -> Bool:
        """`send`, with the `sendmsg` itself as a parameter: the protocol
        around the hand-off, which a test drives by taking the receiver's
        turn inside it.

        The target's `pending` is raised BEFORE the datagram is queued, and
        taken back if nothing was. Raised after, the receiver could admit
        the connection and retire it at the end of its pass in the gap
        between the `sendmsg` and the increment: the retire found nothing
        to take, `pass_end` clamped the count at 0, and the late increment
        left `pending` one high for good, so every `pick` from then on read
        that worker as a connection busier than it was (review record R5).
        Raised first, a datagram the receiver can see was counted before it
        existed, and the count is never below what is in flight.

        The target's `state` is read again after the raise, and a target
        that has left is not sent to: the count is taken back and the
        caller keeps the connection (review record B25). This is the
        sender's half of the handshake in the module docstring.
        """
        if target < 0 or target >= self.workers() or target == self.worker:
            return False
        var payload = List[UInt8](capacity=2 + host.byte_length())
        payload.append(UInt8((port >> 8) & 0xFF))
        payload.append(UInt8(port & 0xFF))
        for b in host.as_bytes():
            payload.append(b)
        var pending = self._word(target, _WORD_PENDING)
        _ = _fetch_add(pending, 1)
        # `pick` read the target's `state` before this raise, and a worker
        # that has left since never reads the channel again once its drain
        # is over. So the word is read again AFTER the raise. A leave this
        # load sees is refused like a failed send. A leave it misses was
        # stored after the load, so its drain reads `pending` after the
        # raise, counts this hand-off, and waits for the datagram
        # (`awaiting_handoffs`). Both sides are sequentially consistent;
        # weaker orderings would let both reads miss.
        if _load(self._word(target, _WORD_STATE)) == STATE_LEFT:
            _ = _fetch_add(pending, -1)
            return False
        if not post.post(self.write_fds[target], fd, payload):
            _ = _fetch_add(pending, -1)
            return False
        self.handoffs_out += 1
        return True

    def receive(mut self, mut host: String, mut port: Int) -> Int:
        """Take one passed connection off this worker's channel: the new
        fd with its peer address; `RECV_FD_EMPTY` when the channel is empty
        (or sharing is inactive); `RECV_FD_REFUSED` when the datagram taken
        carried no descriptor to hand over, which the caller skips.

        A refused hand-off is still retired from `pending` at the end of
        the pass (`drained`). Its sender counted it (`send_with`), and
        nothing else takes that count back: `pick` would read this worker
        as a connection heavier for good, R5's shape. A datagram no sender
        counted can only make the retire overshoot, which `pass_end`
        floors at 0.
        """
        if not self.active():
            return RECV_FD_EMPTY
        var payload = List[UInt8]()
        var fd = recv_fd(self.read_fds[self.worker], payload)
        if fd == RECV_FD_EMPTY:
            return RECV_FD_EMPTY
        self.drained += 1
        # Published for the worker that takes this index if this one dies
        # before `pass_end` retires it (`start`).
        _store(self._word(self.worker, _WORD_TAKEN), self.drained)
        if fd < 0:
            return RECV_FD_REFUSED
        if len(payload) >= 2:
            port = (Int(payload[0]) << 8) | Int(payload[1])
            host = String(from_utf8_lossy=Span(payload)[2:])
        else:
            port = 0
            host = String("")
        self.handoffs_in += 1
        return fd
