"""Deterministic tests for the executor shim's slot-ownership rules.

The shim is a Python program (`packages/m0-wsgi/shim/m0_shim.py`, rendered
into the Mojo constant the binary embeds by `scripts/render_shim.py`), so
its logic can be exercised with no server, no Mojo, no interpreter
embedding and no threads: read the file, `exec` it into a namespace, hand
it a real asyncio loop and a
socketpair for each of the two channels the Mojo loop speaks over, and
drive it exactly as the loop does — 8-byte job datagrams, 9-byte
disconnect tags, 8-byte drain acks. The stand-in for the Mojo side is
`_port`, whose `dispatch` records every event and, for a `('job', slot)`,
calls `spawn` — which is precisely what `ExecutorPort._dispatch` does.

What it pins is the rule the 0.14.0 cycle nearly shipped without: **a
slot's per-slot state in the shim belongs to the slot's CURRENT task, not
to the slot.** The loop recycles a slot the instant it closes a
connection, and the task that owned the previous connection is still alive
for an iteration or two — its cancellation lands at its next await, its
done-callback an iteration later. The failure that produced was a
subscribed stream with no producer: a 30 s client stall against a clean
server log, reproducing 8 of 11 `smoke-asgi` runs under CPU hogs and
vanishing under every instrumentation that added a timer. It was verified
only by an ad-hoc reproducer in a scratchpad; this file is the guard that
was missing.

Four rules, one test each:

* cleanup runs only if the finishing task still owns the slot
  (`_on_task_done`), and it *does* run when it does — the second half is what
  stops "never clean up" from passing as a fix;
* a disconnect is stamped on the owning TASK (`_m0_disconnected`), so a
  lingering task cannot end its successor's stream;
* spawning on a slot clears the slot's stale disconnect mark — and, for a
  WebSocket, the previous socket's accept — so the successor neither
  cancels itself nor answers a handshake it never accepted;
* every "am I gone" check asks `_task_gone`, which consults both marks.

Plus the ack clamp: a drain ack names a slot and no generation, so one for
the stream that just ended can land after the next stream on that slot has
seeded its window whole.

    python3 scripts/shim_ownership.py              # run the tests
    python3 scripts/shim_ownership.py --sabotage   # and prove they bite

`--sabotage` reverts each rule in the extracted source in turn and insists
the suite FAILS for every one — the repo's "every guard is sabotage-
verified" rule, made permanent instead of remembered. A patch that no
longer applies is itself a failure: it means the guarded line was renamed
or deleted, which is the thing this file exists to notice.
"""

import asyncio
import os
import socket
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM = os.path.join(HERE, os.pardir, "packages", "m0-wsgi", "shim", "m0_shim.py")


def shim_source():
    """The shim's Python, as the binary execs it.

    The `.py` is the source of truth; `scripts/render_shim.py` renders it
    into the Mojo constant `bridge.mojo` embeds, and its `--check` (inside
    `poe check-docs`) proves both that the rendering is current and that
    the literal decodes back to this file byte for byte -- which is what
    makes testing the file here the same as testing the binary's program.
    """
    with open(SHIM, "r", encoding="utf-8") as fh:
        return fh.read()


# --- the harness -----------------------------------------------------------

_TAG_DISCONNECT = 1


class Harness:
    """One shim namespace with a live loop and the loop's two channels."""

    def __init__(self, source):
        self.ns = {}
        exec(compile(source, "m0_shim.py", "exec"), self.ns)
        self.loop = asyncio.new_event_loop()
        self.ns["_loop"] = self.loop
        self.ns["_app"] = self._app
        self.events = []
        self.jobs = []          # behaviour per job datagram, in FIFO order
        self.spawned = 0
        self.ns["_port"] = self
        self.ns["set_scope_base"]("testhost", 8088)

        self.submit_r, self.submit_w = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_DGRAM)
        self.ack_r, self.ack_w = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_DGRAM)
        for s in (self.submit_r, self.submit_w, self.ack_r, self.ack_w):
            s.setblocking(False)
        self.ns["asgi_executor_init"](self.submit_r.fileno(),
                                      self.ack_r.fileno())

    # --- the Mojo side's stand-in (ExecutorPort) ---------------------------

    def dispatch(self, ev):
        self.events.append(ev)
        if ev[0] == "job":
            slot = ev[1]
            if slot < 0:
                return True
            behaviour = self.jobs.pop(0)
            if behaviour.startswith("ws"):
                path = {"wsflood": "/ws/flood", "wshold": "/ws/hold",
                        "wsnoanswer": "/ws/noanswer"}.get(behaviour, "/ws")
                self.ns["spawn_ws"](slot, path, b"", "HTTP/1.1", [])
            else:
                # The finished scope, as the bridge's `_build_scope` hands
                # it over: the template's invariant half plus the eight
                # per-request keys.
                scope = dict(self.ns["_scope_base"])
                scope.update({
                    "method": "GET", "path": "/", "raw_path": b"/",
                    "query_string": ("b=%s" % behaviour).encode(),
                    "http_version": "1.1", "headers": [], "client": None,
                    "state": dict(self.ns["_lifespan_state"]),
                })
                self.ns["spawn"](slot, scope, b"")
            self.spawned += 1
        return False

    def flush(self):
        pass

    # --- the application ---------------------------------------------------

    WS_FLOOD_FRAMES = 100
    WS_FLOOD_SIZE = 4096

    async def _app(self, scope, receive, send):
        if scope["type"] == "websocket":
            if scope["path"] == "/ws/noanswer":
                # Returns without ever answering the handshake: the shim's
                # `finally` must resolve the held 101 as a reject.
                return
            await send({"type": "websocket.accept"})
            if scope["path"] == "/ws/hold":
                # Stay inside the accepted socket until cancelled, so a
                # recycle can land while this task is still alive.
                await asyncio.Event().wait()
            if scope["path"] == "/ws/flood":
                for _ in range(self.WS_FLOOD_FRAMES):
                    await send({"type": "websocket.send",
                                "bytes": b"x" * self.WS_FLOOD_SIZE})
                await send({"type": "websocket.close", "code": 1000})
            return
        q = dict(p.split("=", 1) for p in
                 scope["query_string"].decode().split("&") if p)
        behaviour = q.get("b", "hold")
        await send({"type": "http.response.start", "status": 200,
                    "headers": []})
        if behaviour.startswith("child"):
            # Starlette's shape: the body is produced by a task that is
            # not the request task (anyio task group there, a bare
            # create_task here -- what matters is current_task() differs).
            async def body():
                await send({"type": "http.response.body", "body": b"x" * 64,
                            "more_body": True})
                if behaviour == "childfinish":
                    await send({"type": "http.response.body", "body": b"",
                                "more_body": False})
                else:
                    await asyncio.Event().wait()
            await asyncio.create_task(body())
            return
        size = 1024
        if behaviour.startswith("bytes"):
            size = int(behaviour[len("bytes"):])
        await send({"type": "http.response.body", "body": b"x" * size,
                    "more_body": True})
        if behaviour == "finish":
            await send({"type": "http.response.body", "body": b"y" * 16,
                        "more_body": False})
            return
        if behaviour == "slow":
            # The successor has to still be RUNNING when the previous
            # task's done-callback fires an iteration or two later --
            # that callback is the thing under test. A stream that
            # finishes inside its first step never meets it.
            for _ in range(4):
                await asyncio.sleep(0.005)
                await send({"type": "http.response.body", "body": b"z" * 64,
                            "more_body": True})
            await send({"type": "http.response.body", "body": b"",
                        "more_body": False})
            return
        # `hold`/`bytesN`: stay in the stream until something cancels us.
        await asyncio.Event().wait()

    # --- driving the loop --------------------------------------------------

    def job(self, slot, behaviour="hold"):
        self.jobs.append(behaviour)
        self.submit_w.send(int(slot).to_bytes(8, "little", signed=True))

    def disconnect(self, slot):
        self.submit_w.send(
            bytes([_TAG_DISCONNECT])
            + int(slot).to_bytes(8, "little", signed=True))

    def ack(self, slot, nbytes):
        self.ack_w.send(int(slot).to_bytes(4, "little")
                        + int(nbytes).to_bytes(4, "little"))

    def settle(self, passes=60):
        """Run the loop long enough for every reader, task step and
        done-callback queued so far to have run. Each pass is a real
        selector poll, which is what delivers the channel datagrams."""
        async def _spin():
            for _ in range(passes):
                await asyncio.sleep(0.001)
        self.loop.run_until_complete(_spin())

    def close(self):
        for t in list(self.ns["_exec_tasks"]):
            t.cancel()
        self.settle(passes=10)
        self.loop.close()
        for s in (self.submit_r, self.submit_w, self.ack_r, self.ack_w):
            s.close()

    # --- reading the record ------------------------------------------------

    def kinds(self, slot):
        return [e[0] for e in self.events
                if len(e) > 1 and e[1] == slot and e[0] != "job"]


# --- the tests -------------------------------------------------------------
#
# Each takes a Harness and raises AssertionError on failure. The shared
# postcondition every one of them ends with is that the global in-flight
# budget came back whole: a slot torn down without refunding its share
# ratchets `_ASGI_TOTAL_WINDOW` towards zero and stalls every later stream,
# which is the same class of silent failure by another route.


def _assert_global_window_whole(h, note=""):
    total = h.ns["_ASGI_TOTAL_WINDOW"]
    have = h.ns["_exec_global_credit"][0]
    assert have == total, (
        "the global in-flight window did not come back whole%s: %d of %d"
        % (note, have, total))


def _recycle(h, first="bytes32768", second="slow"):
    """The shape of the bug: a stream on a slot, the loop closing it, and
    the NEXT connection landing on the same slot in the same event batch —
    which is exactly how the loop behaves, since it recycles a slot the
    instant it closes one and batches its submits."""
    h.job(0, first)
    h.settle()
    assert h.kinds(0)[:1] == ["stream_start"], (
        "the first request did not start a stream: %r" % (h.kinds(0),))
    mark = len(h.events)
    # One batch: the disconnect for the old connection and the job for the
    # new one, read by a single `_on_submit` callback, in FIFO order.
    h.disconnect(0)
    h.job(0, second)
    h.settle()
    return mark


def test_a_stale_task_does_not_wipe_its_successors_slot_state(h):
    """`_task_done` cleans up only if the finishing task still owns the slot.

    The shipped bug: the previous connection's task finishing a couple of
    iterations late wiped the live task's credit window and event, and the
    live stream then failed on a KeyError inside `_emit` — after its head
    had gone out, so the client saw a truncated body or a stall."""
    _recycle(h)
    # The successor ran to completion, which it cannot do with its credit
    # window pulled out from under it.
    assert h.kinds(0).count("stream_start") == 2, (
        "expected two streams on the slot, got %r" % (h.kinds(0),))
    assert "stream_end" in h.kinds(0), (
        "the successor's stream never ended cleanly: %r" % (h.kinds(0),))
    for ev in h.events:
        if ev[0] in ("err", "stream_note"):
            raise AssertionError(
                "the successor's stream raised: %r" % (ev,))
    _assert_global_window_whole(h)


def test_a_finished_owner_does_clean_its_slot(h):
    """The converse, and the reason the test above cannot be satisfied by
    simply never cleaning up: an owner that finishes MUST release the
    slot's state and refund its in-flight bytes."""
    h.job(0, "finish")
    h.settle()
    assert "stream_end" in h.kinds(0), (
        "the stream did not end: %r" % (h.kinds(0),))
    for name in ("_exec_credits", "_exec_credit_evts", "_exec_stream_tasks",
                 "_exec_slot_task", "_exec_inflight"):
        assert 0 not in h.ns[name], (
            "%s still holds slot 0 after its owner finished" % name)
    _assert_global_window_whole(h)


def test_a_lingering_task_does_not_end_its_successors_stream(h):
    """A disconnect is stamped on the TASK, so the old task's `finally`
    stays quiet even though the slot's mark was cleared for the successor.

    Left on the slot, the old task saw "not gone" (the successor's spawn
    had cleared the mark) and sent an end-of-stream for the slot — under
    the successor's generation. The loop unsubscribed a stream whose
    producer was still running: no more bytes, no close, a 30 s stall."""
    mark = _recycle(h)
    kinds = [e[0] for e in h.events[mark:] if len(e) > 1 and e[1] == 0]
    assert "stream_start" in kinds, (
        "the successor never started: %r" % (kinds,))
    # After the disconnect there is exactly ONE end-shaped event on this
    # slot -- the successor's own, last. The disconnected task must emit
    # none: `_task_gone` is true for it whatever the slot's mark now says,
    # because the mark it carries is its own. A second one here is the old
    # task ending its successor's stream, which the loop reads as
    # end-of-stream and answers by unsubscribing a stream whose producer
    # is still running.
    ends = [i for i, k in enumerate(kinds)
            if k in ("stream_end", "stream_abort")]
    assert ends, "the successor's stream never ended: %r" % (kinds,)
    assert len(ends) == 1, (
        "%d end-shaped events after the disconnect: the task that no "
        "longer owns the slot ended its successor's stream: %r"
        % (len(ends), kinds))
    assert ends[0] == len(kinds) - 1, (
        "the successor's stream was ended before its last chunk: %r"
        % (kinds,))
    _assert_global_window_whole(h)


def test_a_spawn_clears_the_slots_stale_disconnect(h):
    """The successor must not inherit the mark that closed the connection
    before it. Inherited, its first credit wait raises CancelledError and
    its `finally` skips the end signal entirely — a subscribed stream with
    no producer, which is the stall from the other direction."""
    mark = _recycle(h)
    after = [e[0] for e in h.events[mark:] if len(e) > 1 and e[1] == 0]
    assert "stream_end" in after, (
        "the successor did not end its stream cleanly — it inherited the "
        "previous connection's disconnect: %r" % (after,))
    assert "stream_abort" not in after, (
        "the successor aborted rather than ended: %r" % (after,))
    _assert_global_window_whole(h)


def test_a_stale_ack_cannot_inflate_the_successors_window(h):
    """A drain ack names a slot and no generation.

    The loop acks bytes it has flushed for the stream that was on the slot;
    if the connection closes and the next one lands on the same slot before
    that ack is read, the credit belongs to a stream that no longer exists.
    Added, it lets the new stream put more than one window of bytes into
    the ONE shared chunk channel — the over-commit `_ASGI_TOTAL_WINDOW`
    exists to prevent, whose symptom is dropped datagrams and short bodies
    under clean terminators."""
    window = h.ns["_ASGI_CREDIT_WINDOW"]
    h.job(0, "bytes%d" % (window // 2))
    h.settle()
    h.disconnect(0)
    h.job(0, "hold")
    h.settle()
    assert 0 in h.ns["_exec_credits"], "the successor is not streaming"
    # The old connection's ack, arriving late.
    h.ack(0, window // 2)
    h.settle()
    assert h.ns["_exec_credits"][0] <= window, (
        "a stale ack inflated slot 0's credit window to %d (max %d)"
        % (h.ns["_exec_credits"][0], window))


def test_a_websocket_spawn_clears_the_slots_stale_disconnect(h):
    """`spawn_ws` carries the same rule, and the same consequence: a held
    101 whose `websocket.accept` is swallowed as "already gone" is answered
    403 instead — a WebSocket that refuses itself."""
    h.job(0, "hold")
    h.settle()
    # One batch again: the disconnect and the upgrade job are read by a
    # single `_on_submit` callback, so `spawn_ws` runs while the slot's
    # mark is still set -- the only ordering in which the rule matters.
    h.disconnect(0)
    h.job(0, "ws")
    h.settle()
    kinds = h.kinds(0)
    assert "ws_accept" in kinds, (
        "the WebSocket's accept never reached the loop — the slot's stale "
        "disconnect swallowed it: %r" % (kinds,))
    assert "ws_reject" not in kinds, (
        "the handshake was rejected: %r" % (kinds,))


def test_a_websocket_recycle_forgets_the_predecessors_accept(h):
    """`_exec_ws_accepted` names a SLOT; the accept belongs to a task.

    An accepted socket's task is still winding down when the loop recycles
    its slot into a new handshake, and ownership (correctly) keeps its late
    done-callback from wiping the successor's state -- so without the
    spawn-side clear the successor inherits the accept. It then looks
    pre-accepted: an app that returns without answering its handshake sends
    ws_close instead of ws_reject, the held 101 is never released, and the
    client hangs against a clean server log."""
    h.job(0, "wshold")
    h.settle()
    assert "ws_accept" in h.kinds(0), (
        "the first socket was never accepted: %r" % (h.kinds(0),))
    mark = len(h.events)
    # One batch again: the disconnect and the new handshake's job are read
    # by a single `_on_submit` callback, so `spawn_ws` runs while the
    # previous task is still alive and its accept is still on the slot.
    h.disconnect(0)
    h.job(0, "wsnoanswer")
    h.settle()
    after = [e[0] for e in h.events[mark:] if len(e) > 1 and e[1] == 0]
    assert "ws_reject" in after, (
        "the unanswered handshake was not rejected -- the successor "
        "inherited the previous socket's accept: %r" % (after,))
    assert "ws_close" not in after, (
        "the successor closed a socket it never accepted: %r" % (after,))


def test_a_stream_sent_from_a_child_task_marks_the_owner(h):
    """Starlette (FastAPI, FastHTML) produces a StreamingResponse's body
    inside an anyio task group, so `send` arrives from a CHILD task. The
    streaming mark and the cancellable stream task belong to the slot's
    OWNER regardless: marked on the child, the owner's done-callback took
    the stream for a buffered result and raised `TypeError` unpacking
    None -- one traceback per streamed response, in production logs --
    and a disconnect cancelled a task the app's group would restart
    around rather than the request."""
    caught = []
    h.loop.set_exception_handler(lambda loop, ctx: caught.append(ctx))
    # The FastAPI shape: a stream that finishes on its own.
    h.job(0, "childfinish")
    h.settle()
    assert "stream_end" in h.kinds(0), (
        "the child-produced stream did not end: %r" % (h.kinds(0),))
    assert not caught, (
        "a done-callback raised after a finished child-produced stream: %r"
        % (caught[0].get("exception"),))
    # The disconnect shape: the owner must be the task that is marked,
    # recorded for cancellation, and cancelled.
    h.job(1, "childhold")
    h.settle()
    assert h.kinds(1)[:1] == ["stream_start"], (
        "the held child-produced stream did not start: %r" % (h.kinds(1),))
    owner = h.ns["_exec_slot_task"].get(1)
    assert owner is not None, "slot 1 has no owning task"
    assert getattr(owner, "_m0_streaming", False), (
        "the streaming mark landed on the child task, not the owner")
    assert h.ns["_exec_stream_tasks"].get(1) is owner, (
        "the stream task recorded for cancellation is not the owner")
    h.disconnect(1)
    h.settle()
    assert owner.done(), "the owner was not cancelled by the disconnect"
    assert 1 not in h.ns["_exec_slot_task"], (
        "the disconnected owner did not release its slot")
    assert not caught, (
        "a done-callback raised after a disconnected child-produced "
        "stream: %r" % (caught[0].get("exception"),))
    _assert_global_window_whole(h)


def test_a_websocket_send_waits_for_its_window(h):
    """`websocket.send` is credit-gated, so a flooding app waits.

    Ungated it filled the loop's per-slot outbox, and every frame past
    `MAX_PENDING_BYTES` was refused -- a message stream with holes the peer
    has no protocol-level way to detect. The loop already acked a socket's
    drained bytes; the window they are credited to is seeded at
    `websocket.accept`.

    Credit is charged in ENCODED frame bytes, which is what the loop acks,
    so the count here is exact rather than approximate."""
    window = h.ns["_ASGI_CREDIT_WINDOW"]
    frame = h.ns["_ws_frame_bytes"](Harness.WS_FLOOD_SIZE)
    fits = window // frame
    h.job(0, "wsflood")
    h.settle()
    sends = h.kinds(0).count("ws_send")
    assert sends == fits, (
        "%d frames left the app with no acks; one window of %d bytes holds "
        "%d frames of %d. The send is not waiting for credit."
        % (sends, window, fits, frame)
    )
    assert "ws_close" not in h.kinds(0), (
        "the app reached its close while still blocked on the window")
    # Drain-acks for eight frames: exactly eight more must go out.
    h.ack(0, frame * 8)
    h.settle()
    assert h.kinds(0).count("ws_send") == fits + 8, (
        "credit for 8 frames released %d, not 8: %r"
        % (h.kinds(0).count("ws_send") - fits, h.kinds(0)))
    # And the window never exceeds itself, whatever arrives.
    assert h.ns["_exec_credits"][0] <= window


TESTS = [
    test_a_stale_task_does_not_wipe_its_successors_slot_state,
    test_a_finished_owner_does_clean_its_slot,
    test_a_lingering_task_does_not_end_its_successors_stream,
    test_a_spawn_clears_the_slots_stale_disconnect,
    test_a_stale_ack_cannot_inflate_the_successors_window,
    test_a_websocket_spawn_clears_the_slots_stale_disconnect,
    test_a_websocket_recycle_forgets_the_predecessors_accept,
    test_a_websocket_send_waits_for_its_window,
    test_a_stream_sent_from_a_child_task_marks_the_owner,
]


# --- the sabotages ---------------------------------------------------------
#
# One per rule, each reverting it to the shape that shipped the bug (or, for
# the ack clamp, to the shape that has it). Applied to the extracted source,
# so nothing on disk is touched and CI can run this unattended.

SABOTAGES = [
    (
        "the streaming mark goes on the current task, not the slot's owner",
        "                task = _exec_slot_task.get(slot) or asyncio.current_task()",
        "                task = asyncio.current_task()",
    ),
    (
        "_task_gone consults only the slot",
        "    return slot in _exec_disconnected or getattr(\n"
        "        asyncio.current_task(), '_m0_disconnected', False\n"
        "    )",
        "    return slot in _exec_disconnected",
    ),
    (
        "a disconnect is not stamped on the owning task",
        "    owner = _exec_slot_task.get(slot)\n"
        "    if owner is not None:\n"
        "        owner._m0_disconnected = True",
        "    owner = _exec_slot_task.get(slot)",
    ),
    (
        "_task_done cleans up whoever finishes",
        "    if _exec_slot_task.get(slot) is t:",
        "    if t is not None:",
    ),
    (
        "spawn does not clear the slot's stale disconnect",
        "    _exec_disconnected.discard(slot)\n"
        "    _exec_disconnects.pop(slot, None)\n"
        "    task.add_done_callback(cycle.done)",
        "    _exec_disconnects.pop(slot, None)\n"
        "    task.add_done_callback(cycle.done)",
    ),
    (
        "spawn_ws does not clear the slot's stale disconnect",
        "    _exec_disconnected.discard(slot)\n"
        "    _exec_disconnects.pop(slot, None)\n"
        "    _exec_stream_tasks[slot] = task",
        "    _exec_disconnects.pop(slot, None)\n"
        "    _exec_stream_tasks[slot] = task",
    ),
    (
        "spawn_ws does not clear the slot's stale accept",
        "    _exec_ws_accepted.discard(slot)\n"
        "    _exec_disconnected.discard(slot)\n"
        "    _exec_disconnects.pop(slot, None)\n"
        "    _exec_stream_tasks[slot] = task",
        "    _exec_disconnected.discard(slot)\n"
        "    _exec_disconnects.pop(slot, None)\n"
        "    _exec_stream_tasks[slot] = task",
    ),
    (
        "websocket.send is not credit-gated",
        "            await _ws_spend(slot, _ws_frame_bytes(len(payload)))\n"
        "            if _task_gone(slot):\n"
        "                return\n"
        "            _exec_put(('ws_send', slot, opcode, payload))",
        "            _exec_put(('ws_send', slot, opcode, payload))",
    ),
    (
        "a websocket window is never seeded",
        "            _exec_credits[slot] = _ASGI_CREDIT_WINDOW\n"
        "            _exec_credit_evts[slot] = asyncio.Event()\n"
        "            resolved[0] = True",
        "            resolved[0] = True",
    ),
    (
        "a drain ack is added rather than clamped to the window",
        "                credited = _exec_credits[slot] + n\n"
        "                if credited > _ASGI_CREDIT_WINDOW:\n"
        "                    credited = _ASGI_CREDIT_WINDOW\n"
        "                _exec_credits[slot] = credited",
        "                _exec_credits[slot] += n",
    ),
]


def run_suite(source, verbose=True):
    """Every test against one source. Returns the list of failures."""
    failures = []
    for test in TESTS:
        h = Harness(source)
        try:
            test(h)
        except Exception as exc:  # noqa: BLE001 - a failure is data here
            failures.append((test.__name__, exc))
            if verbose:
                print("FAIL %s" % test.__name__)
                traceback.print_exc()
        else:
            if verbose:
                print("ok   %s" % test.__name__)
        finally:
            try:
                h.close()
            except Exception:
                pass
    return failures


def run_sabotages(source):
    """Each rule reverted in turn; every one must break the suite."""
    unproven = []
    for name, old, new in SABOTAGES:
        if source.count(old) != 1:
            print("SABOTAGE PATCH DOES NOT APPLY: %s" % name)
            print("  the guarded lines were renamed, reformatted or removed; "
                  "update SABOTAGES in this file, or the guard is untested")
            unproven.append(name)
            continue
        broken = source.replace(old, new)
        failures = run_suite(broken, verbose=False)
        if failures:
            print("proven  %-58s (%d test(s) fail: %s)"
                  % (name, len(failures),
                     ", ".join(n for n, _ in failures)))
        else:
            print("UNPROVEN %s: the suite still passes with the rule "
                  "reverted" % name)
            unproven.append(name)
    return unproven


def main(argv):
    source = shim_source()
    print("shim-ownership: %d lines of shim read from %s"
          % (len(source.splitlines()), os.path.relpath(SHIM, os.getcwd())))
    failures = run_suite(source)
    if failures:
        print("shim-ownership: %d test(s) failed" % len(failures))
        return 1
    if "--sabotage" in argv:
        print("--- sabotage ---")
        unproven = run_sabotages(source)
        if unproven:
            print("shim-ownership: %d guard(s) unproven" % len(unproven))
            return 1
        print("shim-ownership: %d tests OK, %d guards sabotage-proven"
              % (len(TESTS), len(SABOTAGES)))
        return 0
    print("shim-ownership: %d tests OK" % len(TESTS))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
