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

The load a sibling advertises is three words on its own cache line of the
shared page, so the per-pass stores contend with nothing:

- `state`: 0 while parked in its wait, the pass's start time (ns) while
  it is inside one, `STATE_LEFT` once it is shutting down. A sibling
  inside a pass for longer than `ACCEPT_SHARE_BUSY_NS` is skipped — that
  is a worker running a slow view inline, and handing it a connection
  would queue the client behind that view where the old race, for all
  its unfairness, would have sent it to the idle worker. A worker
  mid-pass for a few microseconds is fine to send to.
- `active`: its open connections, published at the bottom of every pass.
- `pending`: connections passed to it that it has not yet admitted —
  incremented by the sender, decremented by the receiver at the end of
  the pass that admitted them. Without it an acceptor draining a burst
  sees a sibling's stale count of zero thirty-two times over and hands
  it everything.

What can never happen: a lost connection. A send that fails for any
reason (the sibling's channel full, a sibling gone) keeps the connection
where it is; a datagram queued to a worker that crashed waits in the
channel for the respawn, which inherits the same fd by index and drains
it at its first pass. The one window is a sibling that exits at SIGTERM
between the acceptor's check of its `state` and the `sendmsg` — a few
hundred nanoseconds, closed on the receiver's side by draining the
channel once more as its shutdown begins.

Page layout, in Int64 slots of the `SharedAtomics` page `m0serve` creates
pre-fork: slot 0 is the SSE event id (not ours), slot 1 the rotation
counter, and worker `i`'s line starts at slot `8 + 8 * i`. A spawned
worker maps the page by fd with the same slot count.
"""

from std.atomic import Atomic
from std.time import perf_counter_ns

from lightbug_http.c.fdpass import send_fd, recv_fd
from lightbug_http.c.kqueue import set_nonblocking
from lightbug_http.c.socket import setsockopt, SocketOption, SOL_SOCKET
from lightbug_http.c.socketpair import socketpair_dgram


comptime ACCEPT_SHARE_RR_SLOT = 1
"""The rotation counter: where `pick` starts its scan, so equal loads take
turns rather than the lowest index taking every tie."""
comptime ACCEPT_SHARE_FIRST_WORKER_SLOT = 8
"""Worker 0's line begins here — the second 64-byte line of the page."""
comptime ACCEPT_SHARE_WORKER_STRIDE = 8
"""Slots per worker: one cache line each, three of the eight used."""
comptime _WORD_STATE = 0
comptime _WORD_ACTIVE = 1
comptime _WORD_PENDING = 2

comptime ACCEPT_SHARE_BUSY_NS: Int = 2_000_000
"""A sibling inside one pass for longer than this is running something
slow inline and is not handed a connection."""
comptime STATE_LEFT: Int = -1
"""A `state` word meaning the worker is shutting down: never send to it."""
comptime _CHANNEL_BUF = 65536
"""Send and receive buffer for a worker's channel. A passed descriptor's
datagram is under a hundred bytes, so this holds hundreds of connections
in flight to one worker; past that the acceptor keeps them."""


def accept_share_slots(workers: Int) -> Int:
    """How many Int64 slots the shared page needs for `workers` workers."""
    return ACCEPT_SHARE_FIRST_WORKER_SLOT + ACCEPT_SHARE_WORKER_STRIDE * workers


def _atomic(addr: Int) -> Pointer[Atomic[DType.int64], MutUntrackedOrigin]:
    return Pointer[Atomic[DType.int64], MutUntrackedOrigin](
        unsafe_from_address=addr
    )


def _load(addr: Int) -> Int:
    return Int(_atomic(addr)[].load())


def _store(addr: Int, value: Int):
    _atomic(addr)[].store(Int64(value))


def _fetch_add(addr: Int, delta: Int) -> Int:
    return Int(_atomic(addr)[].fetch_add(Int64(delta)))


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

    def __init__(out self):
        self.worker = -1
        self.read_fds = List[Int]()
        self.write_fds = List[Int]()
        self.page = 0
        self.left = False
        self.drained = 0
        self.handoffs_out = 0
        self.handoffs_in = 0

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

    def __init__(out self, *, read_fds: List[Int], write_fds: List[Int]):
        """Adopt channels another process image created (`--spawn-workers`)."""
        self = Self()
        self.read_fds = read_fds.copy()
        self.write_fds = write_fds.copy()

    def __init__(out self, *, copy: Self):
        self.worker = copy.worker
        self.read_fds = copy.read_fds.copy()
        self.write_fds = copy.write_fds.copy()
        self.page = copy.page
        self.left = copy.left
        self.drained = copy.drained
        self.handoffs_out = copy.handoffs_out
        self.handoffs_in = copy.handoffs_in

    def __init__(out self, *, deinit move: Self):
        self.worker = move.worker
        self.read_fds = move.read_fds^
        self.write_fds = move.write_fds^
        self.page = move.page
        self.left = move.left
        self.drained = move.drained
        self.handoffs_out = move.handoffs_out
        self.handoffs_in = move.handoffs_in

    def workers(self) -> Int:
        return len(self.read_fds)

    def bind(mut self, worker: Int, page: Int):
        """Make this the view of worker `worker`, over the page at `page`."""
        self.worker = worker
        self.page = page

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
        return self.page + 8 * (
            ACCEPT_SHARE_FIRST_WORKER_SLOT
            + ACCEPT_SHARE_WORKER_STRIDE * worker + which
        )

    def start(self):
        """At loop start: this worker is parked with no connections.

        `pending` is deliberately NOT reset — a respawned worker inherits
        its predecessor's channel, and the datagrams queued there are
        connections it will admit and account for at its first pass.
        """
        if not self.active():
            return
        _store(self._word(self.worker, _WORD_STATE), 0)
        _store(self._word(self.worker, _WORD_ACTIVE), 0)

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
            var before = _fetch_add(self._word(me, _WORD_PENDING), -self.drained)
            if before - self.drained < 0:
                # A predecessor that died between receiving and retiring
                # left the count high, never low; clamp rather than carry a
                # negative load into every sibling's `pick`.
                _store(self._word(me, _WORD_PENDING), 0)
            self.drained = 0
        if not self.left:
            _store(self._word(me, _WORD_STATE), 0)

    def leave(mut self):
        """Shutting down: siblings must stop sending here."""
        if not self.active():
            return
        self.left = True
        _store(self._word(self.worker, _WORD_STATE), STATE_LEFT)

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
        inside a pass for under `ACCEPT_SHARE_BUSY_NS`, is willing.
        """
        if not self.active():
            return self.worker
        var n = self.workers()
        var me = self.worker
        var start = _fetch_add(self.page + 8 * ACCEPT_SHARE_RR_SLOT, 1) % n
        var best = me
        var best_load = own_active + _load(self._word(me, _WORD_PENDING))
        for k in range(n):
            var i = (start + k) % n
            if i == me:
                continue
            var state = _load(self._word(i, _WORD_STATE))
            if state == STATE_LEFT:
                continue
            if state > 0 and now - state > ACCEPT_SHARE_BUSY_NS:
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
        `fd`. False leaves the caller owning the connection: the target's
        channel is full, or the send failed some other way.
        """
        if target < 0 or target >= self.workers() or target == self.worker:
            return False
        var payload = List[UInt8](capacity=2 + host.byte_length())
        payload.append(UInt8((port >> 8) & 0xFF))
        payload.append(UInt8(port & 0xFF))
        for b in host.as_bytes():
            payload.append(b)
        if not send_fd(self.write_fds[target], fd, payload):
            return False
        _ = _fetch_add(self._word(target, _WORD_PENDING), 1)
        self.handoffs_out += 1
        return True

    def receive(mut self, mut host: String, mut port: Int) -> Int:
        """Take one passed connection off this worker's channel: the new
        fd with its peer address, or -1 when the channel is empty."""
        if not self.active():
            return -1
        var payload = List[UInt8]()
        var fd = recv_fd(self.read_fds[self.worker], payload)
        if fd < 0:
            return -1
        if len(payload) >= 2:
            port = (Int(payload[0]) << 8) | Int(payload[1])
            host = String(from_utf8_lossy=Span(payload)[2:])
        else:
            port = 0
            host = String("")
        self.drained += 1
        self.handoffs_in += 1
        return fd
