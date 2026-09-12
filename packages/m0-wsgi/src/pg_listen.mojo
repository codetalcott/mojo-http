"""A Postgres `NOTIFY` reaching every held stream: the bus's second door.

`m0pub` writes to datagram descriptors the server hands down at fork, so only
code running inside the m0serve process tree can publish. textshelf's own
realtime module records the consequence: "A management command run by hand or
from `flyctl ssh console` publishes to nobody; that is logged once per process
and is not an error." A trigger, a cron job, a second service and `psql` are
all in that position.

Postgres `NOTIFY` is a door every one of them already has. One connection
holding one `LISTEN` turns

    SELECT pg_notify('m0', '{"channel":"room:1","event":"msg","data":"hi"}');

into a frame on the `BroadcastBus`, which reaches every worker's subscribers —
the `--realtime` holds, the grant-verified hold mount, a Mojo mount's own
held stream — exactly as an in-process `publish()` would.

**The payload is three string fields, and that is deliberate.** `channel` says
where it goes, `event` is the SSE event type (optional), and `data` is the SSE
data verbatim. All three are plain JSON strings, so the listener needs
`parse_json_field` and no value-extent scanner: an application that wants
structured data serializes it into `data` itself, which is what
`m0pub.publish` already receives. The frame is built by the same
`format_sse_event` every other publisher here uses, so a client cannot tell
which door an event came through.

**One `LISTEN`, and the payload carries the channel.** Listening per channel
would mean configuring the list up front and re-`LISTEN`ing as it changed;
one well-known channel with the destination inside needs neither. The cost is
that anyone who can `NOTIFY` can reach any channel, which is the same
authority a database write already carries.

Four rules:

  - **Worker 0 only.** Every worker would otherwise open its own connection
    and deliver its own copy of every notification. The tick-owner rule
    `apps/datastar_counter` follows, for the same reason.
  - **`skip_worker` is -1**, so the frame goes to every channel INCLUDING
    this worker's: unlike an in-process publish, nothing has already queued
    it locally.
  - **A malformed payload is refused and counted, never guessed at.** No
    channel, no JSON, an empty name: each is a quiet False and a bump of the
    refused counter, because the payload came from whatever could reach the
    database and one publisher's mistake must not end the listener. This is
    the check that is uniquely this module's — verified by removing it and
    watching the gate go red.
  - **A reserved channel is refused here too, as defence in depth.** The
    namespace `\x01<kind>/<slot>` addresses a connection SLOT on the loop,
    and a name from the database is exactly as untrusted as one from a form
    body. But `publish_to_channels` refuses the same names at the bus
    boundary, so removing this check changes nothing observable — measured:
    the gate stays green with it gone. It is kept because the check that
    matters should be beside the untrusted input as well as at the
    boundary, and it is described as redundant rather than load-bearing so
    nobody mistakes it for the enforcement.
  - **A reset re-`LISTEN`s**, which `Connection.reset` does. A reconnected
    connection is a new backend session listening to nothing, and a listener
    that skipped that step would run forever delivering nothing and logging
    no error — indistinguishable from nobody publishing.

The thread never touches Python and must not: it runs beside an interpreter
it has not attached to. Everything here is Mojo and libpq.
"""

from std.ffi import c_int, external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.time import perf_counter_ns, sleep

from lightbug_http.broadcast import channel_is_reserved, publish_to_channels
from lightbug_http.c.pipe import ShutdownHandle, create_shutdown_pipe
from .blocking_pool import JOIN_TIMEOUT_NS
from m0_core.json_parse import parse_json_field
from m0_http import format_sse_event
from m0_http.multiworker import shared_fetch_add
from m0_http.threads import (
    BLK_SHUTDOWN_FD,
    BLK_STATUS,
    BLK_USER,
    STATUS_OK,
    ThreadBlock,
    ThreadSet,
)
from m0_postgres import Connection, Notification, PgLib, connect_with
from m0_postgres.sqlstate import is_connection_lost


comptime DEFAULT_CHANNEL = "m0"
"""The one channel this listener subscribes to.

Well-known rather than configurable: the destination rides in the payload,
so there is nothing a second channel name would buy that a `channel` field
does not.
"""

comptime POLL_TIMEOUT_MS = 250
"""How long a pass waits before checking the stop pipe again.

A quarter second bounds shutdown without spinning: the wait is in `poll(2)`,
so an idle listener costs four wakeups a second and no CPU between them.
"""

comptime RECONNECT_MIN_MS = 1000
comptime RECONNECT_MAX_MS = 30000
"""Backoff after a lost connection: one second, doubling to thirty.

Bounded at both ends. Retrying instantly against a server that is restarting
is a connection storm at exactly the wrong moment; waiting longer than thirty
seconds makes a recovered server look dead.
"""

comptime POLLIN: Int = 1
comptime POLLERR: Int = 8
comptime POLLHUP: Int = 16
"""The three `revents` bits that mean "stop waiting", the same values on
Linux and macOS.

All three, not just `POLLIN`: a hangup on the stop pipe has to end the
listener as surely as a byte on it, and a hangup on the database socket has
to reach the read that discovers the connection is gone. Waiting only for
`POLLIN` would leave either one parked until the next timeout, forever."""


struct PgListenSpec(Movable):
    """What the listener thread is handed: everything it needs, by address.

    The parent holds this alive until it joins the thread, which is what
    makes the address safe — the same contract `MojoPool`'s `user` address
    has.
    """

    var url: String
    var channel: String
    var write_fds: List[Int]
    var shared_id_addr: Int

    def __init__(
        out self,
        var url: String,
        var channel: String,
        var write_fds: List[Int],
        shared_id_addr: Int,
    ):
        self.url = url^
        self.channel = channel^
        self.write_fds = write_fds^
        self.shared_id_addr = shared_id_addr

    def __init__(out self, *, deinit move: Self):
        self.url = move.url^
        self.channel = move.channel^
        self.write_fds = move.write_fds^
        self.shared_id_addr = move.shared_id_addr


def _say(message: String):
    """One line to stdout, flushed.

    The listener runs on a thread of its own, so an unflushed line could
    appear long after the event it describes — or after a line the loop
    printed later.
    """
    print(message, flush=True)


def _poll_two(fd_a: Int, fd_b: Int, timeout_ms: Int) -> Tuple[Bool, Bool]:
    """`poll(2)` on two descriptors. Returns (a readable, b readable).

    The `pollfd` array is a flat byte buffer rather than a Mojo struct, for
    the reason `lightbug_http/c/epoll.mojo` gives: Mojo cannot vary a
    struct's fields by target, and a struct whose size is wrong corrupts
    everything after the first element in silence. `pollfd` is the same
    eight bytes on both targets here — `int fd; short events; short
    revents` — which is why two of them is a 16-byte buffer.
    """
    var buf = unsafe_alloc[UInt8](count=16)
    for i in range(16):
        buf[unsafe_offset=i] = 0
    var words = buf.unsafe_bitcast[Int32]()
    var shorts = buf.unsafe_bitcast[Int16]()
    words[unsafe_offset=0] = Int32(fd_a)
    shorts[unsafe_offset=2] = Int16(POLLIN)
    words[unsafe_offset=2] = Int32(fd_b)
    shorts[unsafe_offset=6] = Int16(POLLIN)
    var rc = Int(
        external_call["poll", c_int, Int, Int, c_int](
            Int(buf), 2, c_int(timeout_ms)
        )
    )
    var a = False
    var b = False
    if rc > 0:
        comptime READY = POLLIN | POLLERR | POLLHUP
        a = (Int(shorts[unsafe_offset=3]) & READY) != 0
        b = (Int(shorts[unsafe_offset=7]) & READY) != 0
    buf.unsafe_free()
    return (a, b)


def _deliver(ref spec: PgListenSpec, payload: String) -> Bool:
    """Turn one notification payload into a bus frame. True if it went out.

    Every refusal is a quiet False rather than an error: the payload came
    from whatever could reach the database, and a malformed one is that
    writer's problem, not a reason to end the listener. The caller logs a
    count, which is what makes a systematically wrong publisher visible
    without a line per event.
    """
    var channel = parse_json_field(payload, "channel")
    if not channel:
        return False
    if channel_is_reserved(channel):
        # The control namespace addresses connection slots on the loop. A
        # name from the database is as untrusted as one from a form body.
        return False
    var event = parse_json_field(payload, "event")
    var data = parse_json_field(payload, "data")
    var event_id = 0
    if spec.shared_id_addr != 0:
        event_id = shared_fetch_add(spec.shared_id_addr, 1) + 1
    var frame = format_sse_event(event_id, event, data)
    # skip_worker = -1: every channel, this worker's included. Nothing has
    # queued this locally, unlike an in-process publish.
    publish_to_channels(
        spec.write_fds, -1, channel, event_id, frame.as_bytes()
    )
    return True


def listener_body(arg: Int) -> Int:
    """The listener thread: connect, LISTEN, poll, publish, repeat.

    Runs until the stop pipe becomes readable. Never touches Python — it
    runs beside an interpreter it has not attached to, and attaching would
    make it one more GIL waiter for no reason.
    """
    var block = ThreadBlock(arg)
    var stop_fd = block.get(BLK_SHUTDOWN_FD)
    ref spec = Pointer[PgListenSpec, MutUntrackedOrigin](
        unsafe_from_address=block.get(BLK_USER)
    )[]

    var backoff_ms = RECONNECT_MIN_MS
    var delivered = 0
    var refused = 0

    while True:
        # --- establish ---------------------------------------------------
        var db: Connection
        try:
            db = connect_with(PgLib.open(), spec.url)
            db.listen(spec.channel)
        except e:
            _say("pg-listen: " + String(e))
            # Wait by POLLING the stop pipe rather than sleeping through it,
            # so a SIGTERM during a backoff is answered now and not up to
            # thirty seconds later.
            var waited = _poll_two(stop_fd, stop_fd, backoff_ms)
            if waited[0]:
                block.set(BLK_STATUS, STATUS_OK)
                return 0
            backoff_ms = min(backoff_ms * 2, RECONNECT_MAX_MS)
            continue

        _say(
            "pg-listen: listening on `" + spec.channel + "` at "
            + db.url_for_logs
        )
        backoff_ms = RECONNECT_MIN_MS

        # --- serve, recovering in place while that works -----------------
        while True:
            var ready = _poll_two(db.socket_fd(), stop_fd, POLL_TIMEOUT_MS)
            if ready[1]:
                db.close()
                _say(
                    "pg-listen: stopping after " + String(delivered)
                    + " delivered, " + String(refused) + " refused"
                )
                block.set(BLK_STATUS, STATUS_OK)
                return 0
            if not ready[0]:
                continue

            var lost = False
            while True:
                var note: Optional[Notification]
                try:
                    note = db.notifies()
                except e:
                    _say("pg-listen: " + String(e))
                    lost = True
                    break
                if not note:
                    break
                if _deliver(spec, note.value().payload):
                    delivered += 1
                else:
                    refused += 1
            if not lost:
                continue

            # Recover on this connection first: `reset` re-LISTENs what it
            # was told to listen to, which is the half that is invisible
            # when it is missing. Only if that fails do we drop out and
            # build a new connection, after a backoff.
            try:
                db.reset()
                _say("pg-listen: reconnected")
                continue
            except e:
                _say("pg-listen: reconnect failed: " + String(e))
                break

        var waited = _poll_two(stop_fd, stop_fd, backoff_ms)
        if waited[0]:
            block.set(BLK_STATUS, STATUS_OK)
            return 0
        backoff_ms = min(backoff_ms * 2, RECONNECT_MAX_MS)


struct PgListener(Movable):
    """The listener thread's handle: start it, stop it, join it.

    Inert when `--pg-listen` is absent (`active` False), which is what keeps
    the cost of the feature at one Bool check for every server that does not
    use it — and keeps libpq unopened, since the library is resolved by the
    thread rather than at load time.
    """

    var _specs: List[PgListenSpec]
    """Exactly one spec, in a `List` on purpose.

    The thread is handed the spec's ADDRESS, so that address must not move
    while the thread runs. A `List`'s buffer is heap-allocated and stays put
    when the `List` itself is moved, which a plain field would not.
    """

    var _threads: ThreadSet
    var _stop: ShutdownHandle
    var active: Bool

    def __init__(out self):
        """The inert listener: no thread, no connection, no libpq."""
        self._specs = List[PgListenSpec]()
        self._threads = ThreadSet(0)
        self._stop = ShutdownHandle(-1)
        self.active = False

    def __init__(out self, *, deinit move: Self):
        self._specs = move._specs^
        self._threads = move._threads^
        self._stop = move._stop^
        self.active = move.active

    @staticmethod
    def start(
        url: String,
        channel: String,
        write_fds: List[Int],
        shared_id_addr: Int,
    ) raises -> Self:
        """Spawn the listener on this process. Call on worker 0 only.

        Every worker running one would open its own connection and deliver
        its own copy of every notification — the tick-owner rule, in another
        place.
        """
        var out = Self()
        out._specs.append(
            PgListenSpec(url, channel, write_fds.copy(), shared_id_addr)
        )
        var pair = create_shutdown_pipe()
        out._threads = ThreadSet(1)
        out._threads.block(0).set(BLK_SHUTDOWN_FD, pair[0])
        out._threads.block(0).set(BLK_USER, Int(out._specs.unsafe_ptr()))
        # By fd number, as `ShutdownFanout` does: the handle owns no
        # resource beyond the descriptor and has no destructor, so a
        # second one over the same number is the same write end.
        out._stop = ShutdownHandle(pair[1].fd)
        # Bound to a local first: the address has to be taken off a value
        # with an origin, which a bare function name is not.
        var body = listener_body
        out._threads.spawn(0, Pointer(to=body).unsafe_bitcast[Int]()[])
        out.active = True
        return out^

    def stop(mut self) raises:
        """Ask the listener to finish, and wait for it.

        Bounded the way every other join in this server is: a thread parked
        in `poll` answers within one timeout, and one inside libpq answers
        when its syscall returns. Past the budget the caller leaves without
        it rather than making SIGTERM a no-op, which is what an unbounded
        `pthread_join` would do.
        """
        if not self.active:
            return
        self.active = False
        self._stop.notify()
        _ = self._threads.join_within(JOIN_TIMEOUT_NS)
