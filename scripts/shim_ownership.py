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

The rules, each with a test:

* cleanup runs only if the finishing task still owns the slot
  (`_on_task_done`), and it *does* run when it does — the second half is what
  stops "never clean up" from passing as a fix;
* a disconnect is stamped on the owning TASK (`_m0_disconnected`), so a
  lingering task cannot end its successor's stream;
* spawning a WebSocket on a slot clears the previous socket's accept, so the
  successor does not answer a handshake it never accepted;
* every "am I gone" check asks `_task_gone(owner)` about the task that owns
  the connection a send ADDRESSES — stamped, or finished — never about the
  caller. Judged by the caller (the rule until 2026-09-22), a disconnect
  hook's sends to the sockets still connected were refused, and a send kept
  for a client that had gone reached the next client on its recycled slot:
  FastAPI's documented chat room delivered a departed client's messages to
  a stranger (SPEC L20). A send to a gone socket raises
  `ClientDisconnected`; one to a gone stream is a no-op (ASGI 2.3).

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
        self.ws_sends = []      # every socket's send, in accept order
        self.http_sends = []    # every stored stream's send
        self.cleanups = []      # disconnect codes an app's cleanup saw
        self.second_receive = []  # what a receive() after the disconnect got
        self.release = asyncio.Event()  # lets a background task finish
        self.bg_done = False
        self.http_receives = []  # every stored stream's receive
        self.bg_receive = []     # what a receive() after the response got
        self.head_receive = []   # what a receive() after a streamed HEAD got
        self.head_finished = False  # the streamed HEAD's app ran to its end
        self.head_task = None    # a HEAD application's own task
        self.linger_cancels = 0  # cancels a lingering stream task saw
        self.forever_ended = False  # the endless background task's finally ran
        self.slowbg_done = False    # a short background task finished
        self.latebg_done = False    # background work begun inside the drain
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
                        "wsnoanswer": "/ws/noanswer", "wschat": "/ws/chat",
                        "wskeep": "/ws/keep", "wsquick": "/ws/quick",
                        "wsexcept": "/ws/except", "wsblocked": "/ws/blocked",
                        "wsboom": "/ws/boom", "wsescape": "/ws/escape",
                        "wsclosehold": "/ws/closehold",
                        "wsclosewait": "/ws/closewait",
                        "wsclosetwice": "/ws/closetwice",
                        "wscloserecv": "/ws/closerecv",
                        }.get(behaviour, "/ws")
                self.ns["spawn_ws"](slot, path, b"", "HTTP/1.1", [])
            else:
                # The finished scope, as the bridge's `_build_scope` hands
                # it over: the template's invariant half plus the eight
                # per-request keys.
                scope = dict(self.ns["_scope_base"])
                scope.update({
                    "method": "HEAD" if behaviour.startswith("head") else "GET",
                    "path": "/", "raw_path": b"/",
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
            if scope["path"] == "/ws/chat":
                # A chat room's disconnect hook: when this client leaves,
                # tell every other socket. The hook runs on THIS task, whose
                # client has gone, and in a `finally`, so it runs whether
                # the server delivers the disconnect or cancels
                # (FastHTML's `disconn` shape).
                me = len(self.ws_sends)
                self.ws_sends.append(send)
                try:
                    while (await receive())["type"] != "websocket.disconnect":
                        pass
                finally:
                    self.ws_sends[me] = None
                    for other in self.ws_sends:
                        if other is not None:
                            try:
                                await other({"type": "websocket.send",
                                             "bytes": b"left:%d" % me})
                            except Exception:
                                pass
                return
            if scope["path"] == "/ws/keep":
                # An app that keeps every socket's send and never prunes:
                # the shape that leaked another client's messages.
                self.ws_sends.append(send)
                while (await receive())["type"] != "websocket.disconnect":
                    pass
                return
            if scope["path"] == "/ws/quick":
                self.ws_sends.append(send)
                return
            if scope["path"] == "/ws/except":
                # FastAPI's documented shape: the cleanup is AFTER the
                # receive loop (`except WebSocketDisconnect:`), not in a
                # finally, so a cancellation skips it.
                while True:
                    msg = await receive()
                    if msg["type"] == "websocket.disconnect":
                        break
                self.cleanups.append(msg.get("code"))
                again = await receive()
                self.second_receive.append(again["type"])
                return
            if scope["path"] == "/ws/blocked":
                # Forwards from somewhere else and never calls receive():
                # nothing can tell it the client has gone until it sends.
                await asyncio.Event().wait()
            if scope["path"] == "/ws/boom":
                raise RuntimeError("ws kaboom")
            if scope["path"] == "/ws/closehold":
                # Closes its own socket, keeps its send, and stays alive
                # without receiving. The loop tells the executor nothing
                # about a socket the APPLICATION closed: its close frame
                # ends the subscription before the connection closes.
                self.ws_sends.append(send)
                await send({"type": "websocket.close", "code": 1000})
                await asyncio.Event().wait()
            if scope["path"] == "/ws/closewait":
                await send({"type": "websocket.close", "code": 1000})
                await asyncio.sleep(0.05)
                return
            if scope["path"] == "/ws/closetwice":
                await send({"type": "websocket.close", "code": 1000})
                await send({"type": "websocket.close", "code": 1000})
                return
            if scope["path"] == "/ws/closerecv":
                # After its own close an app waits for the client's reply:
                # uvicorn answers it with websocket.disconnect.
                await send({"type": "websocket.close", "code": 1000})
                msg = await receive()
                if msg["type"] == "websocket.connect":
                    # The handshake's own message, which these apps skip.
                    msg = await receive()
                self.second_receive.append(msg["type"])
                return
            if scope["path"] == "/ws/escape":
                # Push-only, and it lets the disconnect signal escape.
                while True:
                    await send({"type": "websocket.send", "text": "tick"})
                    await asyncio.sleep(0.005)
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
        if behaviour == "failbefore":
            raise KeyError("kaboom before")
        if behaviour == "leftover":
            # Returns WITHOUT answering and leaves a task that answers
            # later -- an ASGI violation whose late answer must reach
            # nobody, the slot's next request least of all.
            async def late():
                await asyncio.sleep(0.02)
                await send({"type": "http.response.start", "status": 200,
                            "headers": []})
                await send({"type": "http.response.body", "body": b"LATE",
                            "more_body": False})
            asyncio.get_running_loop().create_task(late())
            return
        if behaviour in ("swallow", "swallowlate", "latebg"):
            # Background work after an answered response: `latebg` waits
            # for the test's release, then works 50 ms; `swallow` swallows
            # ONE cancellation and keeps going for 0.3 s; `swallowlate`
            # has not answered yet, swallows its cancellation, and answers
            # 0.2 s later -- a task the drain leaves behind that finishes
            # afterwards (the tests shrink _CANCEL_GRACE below that).
            if behaviour != "swallowlate":
                await send({"type": "http.response.start", "status": 200,
                            "headers": []})
                await send({"type": "http.response.body", "body": b"ok",
                            "more_body": False})
            if behaviour == "latebg":
                await self.release.wait()
                await asyncio.sleep(0.05)
                self.latebg_done = True
                return
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                pass
            await asyncio.sleep(0.2 if behaviour == "swallowlate" else 0.3)
            if behaviour == "swallowlate":
                await send({"type": "http.response.start", "status": 200,
                            "headers": []})
                await send({"type": "http.response.body", "body": b"late",
                            "more_body": False})
            return
        if behaviour in ("forever", "slowbg"):
            # Answered, then background work: endless, or a short job that
            # must be allowed to finish inside the drain's grace.
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await send({"type": "http.response.body", "body": b"ok",
                        "more_body": False})
            if behaviour == "slowbg":
                await asyncio.sleep(0.02)
                self.slowbg_done = True
                return
            try:
                while True:
                    await asyncio.sleep(0.01)
            finally:
                self.forever_ended = True
        if behaviour == "linger":
            # A stream that outlives its disconnect: its cleanup swallows
            # the first cancel (a finally doing slow work), and counts
            # every cancel it is sent.
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await send({"type": "http.response.body", "body": b"x" * 64,
                        "more_body": True})
            while True:
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    self.linger_cancels += 1
                    if self.linger_cancels > 1:
                        raise
        if behaviour == "longpoll":
            # Parked in receive() before answering: its disconnect arrives
            # there, and nothing else of it is a stream.
            await receive()
            await receive()
            return
        if behaviour == "bodyfirst":
            # A body before its start, the error caught, then a proper
            # answer: only the proper answer may reach the client.
            try:
                await send({"type": "http.response.body", "body": b"stray",
                            "more_body": False})
            except RuntimeError:
                pass
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await send({"type": "http.response.body", "body": b"ok",
                        "more_body": False})
            return
        if behaviour in ("twice", "bgreceive", "bgclientdisc"):
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await send({"type": "http.response.body", "body": b"first",
                        "more_body": False})
            if behaviour == "twice":
                await send({"type": "http.response.body", "body": b"second",
                            "more_body": False})
            if behaviour == "bgreceive":
                await receive()             # the request's own body
                msg = await receive()       # after the response is answered
                self.bg_receive.append(msg["type"])
            if behaviour == "bgclientdisc":
                raise self.ns["ClientDisconnected"]()
            return
        if behaviour == "finallyend":
            # Ends its stream from a finally: after a disconnect, that
            # final body arrives on a task the loop has already let go of.
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await send({"type": "http.response.body", "body": b"x" * 64,
                        "more_body": True})
            try:
                await asyncio.Event().wait()
            finally:
                await send({"type": "http.response.body", "body": b"",
                            "more_body": False})
        if behaviour in ("background", "plain", "failafter"):
            status = 500 if behaviour == "failafter" else 200
            await send({"type": "http.response.start", "status": status,
                        "headers": []})
            body = {"background": b"answered", "plain": b"plain",
                    "failafter": b"app error page"}[behaviour]
            await send({"type": "http.response.body", "body": body,
                        "more_body": False})
            if behaviour == "background":
                # Starlette's shape: a response's background tasks run
                # after its final body, inside the same call.
                await self.release.wait()
                self.bg_done = True
            if behaviour == "failafter":
                # ServerErrorMiddleware's shape: a finished 500, then the
                # re-raise of the error it was for.
                raise ValueError("kaboom after body")
            return
        if behaviour == "headlisten":
            # Starlette's StreamingResponse under ASGI 2.3: a listener parked
            # in receive() from before the first body, beside a task that
            # produces an endless body; the listener's disconnect cancels the
            # body, and the response's background work would run after.
            self.head_task = asyncio.current_task()
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})

            async def body():
                while True:
                    await send({"type": "http.response.body",
                                "body": b"x" * 64, "more_body": True})
                    await asyncio.sleep(0.001)
            producer = asyncio.get_running_loop().create_task(body())
            await receive()  # the request's own body
            self.head_receive.append((await receive())["type"])
            producer.cancel()
            self.head_finished = True
            return
        if behaviour == "headforever":
            # asgi_bare's /stream-forever: an endless body and no receive()
            # at all, so nothing can tell it that its response is over.
            self.head_task = asyncio.current_task()
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            while True:
                await send({"type": "http.response.body", "body": b"x" * 64,
                            "more_body": True})
                await asyncio.sleep(0.001)
        if behaviour in ("headstream", "stream204"):
            # A streaming application answering a HEAD as it answers a GET,
            # as Starlette's StreamingResponse does -- or streaming into a
            # status that has no content: a head, three streamed pieces and
            # a final body, then what receive() says afterwards.
            status, head = 200, [(b"content-type", b"text/plain")]
            if behaviour == "stream204":
                status, head = 204, []
            await send({"type": "http.response.start", "status": status,
                        "headers": head})
            for _ in range(3):
                await send({"type": "http.response.body", "body": b"x" * 64,
                            "more_body": True})
            await send({"type": "http.response.body", "body": b"",
                        "more_body": False})
            await receive()  # the request's own body
            self.head_receive.append((await receive())["type"])
            self.head_finished = True
            return
        if behaviour == "streambg":
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await send({"type": "http.response.body", "body": b"x" * 64,
                        "more_body": True})
            await send({"type": "http.response.body", "body": b"",
                        "more_body": False})
            await self.release.wait()
            self.bg_done = True
            return
        await send({"type": "http.response.start", "status": 200,
                    "headers": []})
        if behaviour == "storehold":
            # A push hub: keep the stream's send for later, then hold.
            await send({"type": "http.response.body", "body": b"hello",
                        "more_body": True})
            self.http_sends.append(send)
            self.http_receives.append(receive)
            await asyncio.Event().wait()
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

    def disconnect(self, slot, code=0):
        """The loop's disconnect tag; `code`, when given, is a WebSocket's
        close code in the tag's 11-byte shape (SPEC L28)."""
        self.submit_w.send(
            bytes([_TAG_DISCONNECT])
            + int(slot).to_bytes(8, "little", signed=True)
            + (int(code).to_bytes(2, "little") if code else b""))

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

    def run(self, coro):
        """Run one coroutine to completion on the harness loop."""
        return self.loop.run_until_complete(coro)

    def pill(self):
        """The loop's shutdown: an 8-byte job for slot -1."""
        self.submit_w.send((-1).to_bytes(8, "little", signed=True))

    def run_until_stopped(self, timeout):
        """Run the loop until the shim stops it; False if `timeout` ran
        out first."""
        fired = []

        def expire():
            fired.append(True)
            self.loop.stop()

        handle = self.loop.call_later(timeout, expire)
        self.loop.run_forever()
        handle.cancel()
        return not fired

    async def foreign(self, send, message):
        """Call a connection's `send` from a task that is NOT that
        connection's: a background task, another request, a hub. Returns
        "returned", or the name of what it raised."""
        async def call():
            try:
                await send(message)
                return "returned"
            except BaseException as exc:  # noqa: BLE001 - it is the datum
                return type(exc).__name__
        return await asyncio.get_running_loop().create_task(call())

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


def test_a_successor_does_not_inherit_its_predecessors_disconnect(h):
    """The successor must not inherit the disconnect that closed the
    connection before it. Inherited, its first credit wait raises CancelledError and
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


def test_a_websocket_successor_does_not_inherit_its_predecessors_disconnect(h):
    """`spawn_ws` carries the same rule, and the same consequence: a held
    101 whose `websocket.accept` is swallowed as "already gone" is answered
    403 instead — a WebSocket that refuses itself."""
    h.job(0, "hold")
    h.settle()
    # One batch again: the disconnect and the upgrade job are read by a
    # single `_on_submit` callback, so `spawn_ws` runs while the previous
    # connection's disconnect is still pending on the slot -- the only
    # ordering in which the rule matters.
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


def test_a_gone_sockets_hook_can_send_to_the_others(h):
    """A send is judged by the connection it ADDRESSES, not by the task
    making it. A chat room's disconnect hook runs on the task whose client
    has gone and sends to the sockets still here. Judged by the caller, every
    one of those sends was refused silently: "someone left" reached 0 of 3
    clients where uvicorn delivered 3 of 3."""
    h.job(0, "wschat")
    h.job(1, "wschat")
    h.settle()
    assert "ws_accept" in h.kinds(0) and "ws_accept" in h.kinds(1), (
        "both sockets were not accepted: %r / %r" % (h.kinds(0), h.kinds(1)))
    mark = len(h.events)
    h.disconnect(0)
    h.settle()
    told = [e[3] for e in h.events[mark:] if e[0] == "ws_send" and e[1] == 1]
    assert told == [b"left:0"], (
        "the socket still connected was not told who left: %r" % (told,))


def test_a_stale_socket_send_never_reaches_the_slots_next_client(h):
    """The security half. The loop recycles a slot the instant it closes a
    connection, so a send kept by the application for a client that has
    gone, called from any live task, addressed the NEXT client on that
    slot. Measured on FastAPI's documented chat example: the new client
    received every message meant for the one that left. It must raise, as
    uvicorn's `ClientDisconnected` does, and emit nothing."""
    h.job(0, "wskeep")
    h.settle()
    stale = h.ws_sends[0]
    # One batch: the old client's disconnect, and a new client's handshake
    # landing on the same slot.
    h.disconnect(0)
    h.job(0, "wskeep")
    h.settle()
    assert h.kinds(0).count("ws_accept") == 2, (
        "the second client was not accepted on the slot: %r" % (h.kinds(0),))
    mark = len(h.events)
    result = h.run(h.foreign(stale, {"type": "websocket.send",
                                     "text": "for the client who left"}))
    leaked = [e for e in h.events[mark:] if e[0] == "ws_send" and e[1] == 0]
    assert not leaked, (
        "a message for the client who left was sent to the slot's new "
        "client: %r" % (leaked,))
    assert result == "ClientDisconnected", (
        "a send to a gone socket must raise ClientDisconnected, got %r"
        % (result,))


def test_a_send_from_a_finished_socket_is_refused(h):
    """A socket whose application returned is over. Its task finished and
    released the slot BEFORE the loop's disconnect tag, so nothing stamped
    it; being finished is what makes it gone."""
    h.job(0, "wsquick")
    h.settle()
    stale = h.ws_sends[0]
    h.disconnect(0)
    h.job(0, "wskeep")
    h.settle()
    mark = len(h.events)
    result = h.run(h.foreign(stale, {"type": "websocket.send",
                                     "text": "late"}))
    leaked = [e for e in h.events[mark:] if e[0] == "ws_send" and e[1] == 0]
    assert not leaked, (
        "a finished socket's send reached the slot's new client: %r"
        % (leaked,))
    assert result == "ClientDisconnected", result


def test_a_stale_stream_send_never_reaches_the_slots_next_response(h):
    """The same leak on a streamed HTTP response: a push hub's stale
    `send` wrote "PRIVATE for xavier" into yara's stream. Under the spec
    version this server advertises (2.3) a send after a disconnect is a
    no-op, and uvicorn's is: it must return quietly and emit nothing."""
    h.job(0, "storehold")
    h.settle()
    stale = h.http_sends[0]
    h.disconnect(0)
    h.job(0, "hold")
    h.settle()
    assert h.kinds(0).count("stream_start") == 2, (
        "the second stream did not start on the slot: %r" % (h.kinds(0),))
    mark = len(h.events)
    result = h.run(h.foreign(stale, {"type": "http.response.body",
                                     "body": b"STALE", "more_body": True}))
    leaked = [e for e in h.events[mark:]
              if e[0] == "stream_chunk" and e[1] == 0 and b"STALE" in e[2]]
    assert not leaked, (
        "a gone stream's bytes were written into the slot's next response")
    assert result == "returned", (
        "a send to a gone stream must be a quiet no-op, got %r" % (result,))
    # (No whole-window check here: the successor is still holding its first
    # 1024 bytes in flight, unacked, which is what a live stream does.)


def test_a_socket_disconnect_reaches_the_app_through_receive(h):
    """uvicorn's contract, and the one FastAPI's documentation is written
    against: the disconnect is a `websocket.disconnect` from receive(), and
    the task is NOT cancelled. Cancelled, the `except WebSocketDisconnect:`
    cleanup never ran: the departed client stayed in the manager's list for
    ever and every later broadcast walked into it."""
    h.job(0, "wsexcept")
    h.settle()
    task = h.ns["_exec_slot_task"][0]
    h.disconnect(0)
    h.settle()
    assert h.cleanups == [1006], (
        "the app's own disconnect cleanup did not run: %r" % (h.cleanups,))
    assert not task.cancelled(), "the socket's task was cancelled"


def test_a_receive_after_the_disconnect_says_so_again(h):
    """Nothing will ever fill the queue again, so a second receive() must
    not wait on it. With the task no longer cancelled, that wait would hold
    it for ever."""
    h.job(0, "wsexcept")
    h.settle()
    h.disconnect(0)
    h.settle()
    assert h.second_receive == ["websocket.disconnect"], (
        "a receive() after the disconnect did not return it again: %r"
        % (h.second_receive,))


def test_the_drain_ends_a_socket_blocked_outside_receive(h):
    """A socket task is told through receive() and never cancelled for it,
    so one that never calls receive() is still running at shutdown. The
    drain gives every task the grace, then cancels the sockets still
    running. Without that, shutdown waits for them until the Mojo join's
    5 s bound, then `_exit`s."""
    h.ns["_WS_DRAIN_GRACE"] = 0.05
    h.job(0, "wsblocked")
    h.settle()
    task = h.ns["_exec_slot_task"][0]
    h.disconnect(0)
    h.settle()
    assert not task.done(), "the blocked socket's task was cancelled early"
    h.pill()
    assert h.run_until_stopped(timeout=3.0), (
        "the executor never stopped: the drain waited on a socket task "
        "blocked outside receive()")
    assert task.cancelled(), "the drain stopped without ending the socket"


def test_a_response_is_answered_at_its_final_body(h):
    """Starlette runs a response's background tasks after its final body,
    inside the same call, so answering when the application RETURNED held
    every such response for as long as its background work took: 1.5 s for
    a task that sleeps 1.5 s, where uvicorn answers at once."""
    h.job(0, "background")
    h.settle()
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1 and done[0][4] == b"answered", (
        "the response was not answered while its background work ran: %r"
        % (h.kinds(0),))
    first = h.ns["_exec_slot_task"][0]
    assert not first.done(), "the background work is not still running"
    # Keep-alive: the next request on the same connection is served while
    # the first request's background work runs...
    h.job(0, "plain")
    h.settle()
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert [d[4] for d in done] == [b"answered", b"plain"], (
        "the second request was not answered: %r" % (h.kinds(0),))
    # ...and the client leaving does not cancel that work.
    h.disconnect(0)
    h.settle()
    assert not first.cancelled(), "the disconnect cancelled background work"
    h.release.set()
    h.settle()
    assert h.bg_done, "the background work never finished"
    assert h.kinds(0).count("done") == 2 and "err" not in h.kinds(0), (
        "the late finish answered the slot again: %r" % (h.kinds(0),))


def test_a_stream_ends_at_its_final_body(h):
    """The streamed path had the same wait (its end frame was sent from
    `run`'s finally), and it is the path every response takes under
    Starlette's BaseHTTPMiddleware."""
    h.job(0, "streambg")
    h.settle()
    assert "stream_end" in h.kinds(0), (
        "the stream did not end while its background work ran: %r"
        % (h.kinds(0),))
    owner = h.ns["_exec_slot_task"][0]
    h.disconnect(0)
    h.settle()
    assert not owner.cancelled(), (
        "a disconnect after the stream ended cancelled its background work")
    h.release.set()
    h.settle()
    assert h.bg_done
    ends = [k for k in h.kinds(0) if k in ("stream_end", "stream_abort")]
    assert ends == ["stream_end"], ends


def test_an_error_after_the_final_body_keeps_the_apps_response(h):
    """ServerErrorMiddleware sends a finished 500 and THEN re-raises. The
    executor used to answer with its own "Failed to process request", so a
    FastHTML developer never saw `debug=True`'s traceback page."""
    h.job(0, "failafter")
    h.settle()
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1 and done[0][2] == 500 \
        and done[0][4] == b"app error page", (
            "the application's own 500 was not what answered: %r" % (done,))
    assert "err" not in h.kinds(0), "the slot was answered twice"
    logs = [e[2] for e in h.events if e[0] == "log" and e[1] == 0]
    assert logs and "kaboom after body" in logs[0], (
        "the late error never reached the log: %r" % (logs,))


def test_an_error_before_the_response_is_logged_with_its_traceback(h):
    """The log line was `request raised: KeyError: 'kaboom before'`. The
    file and line an application author needs were nowhere, where uvicorn
    logs the traceback."""
    h.job(0, "failbefore")
    h.settle()
    errs = [e[2] for e in h.events if e[0] == "err" and e[1] == 0]
    assert errs, "no error was reported: %r" % (h.kinds(0),)
    assert errs[0].splitlines()[0] == "KeyError: 'kaboom before'", errs[0]
    assert "Traceback (most recent call last)" in errs[0], (
        "the error was reported without its traceback: %r" % (errs[0],))


def test_a_late_error_is_logged_with_its_traceback(h):
    h.job(0, "failafter")
    h.settle()
    logs = [e[2] for e in h.events if e[0] == "log" and e[1] == 0]
    assert logs and "Traceback (most recent call last)" in logs[0], logs


def test_a_socket_whose_app_raises_closes_with_1011(h):
    """RFC 6455 7.4.1: 1011 is "an unexpected condition". 1000 told the
    client that all went well."""
    h.job(0, "wsboom")
    h.settle()
    codes = [e[2] for e in h.events if e[0] == "ws_close" and e[1] == 0]
    assert codes == [1011], "a raising app's socket closed with %r" % codes
    notes = [e[2] for e in h.events if e[0] == "stream_note" and e[1] == 0]
    assert notes and "ws kaboom" in notes[0] \
        and "Traceback (most recent call last)" in notes[0], notes


def test_a_disconnect_that_escapes_the_app_is_not_an_error(h):
    """The client left and the app let ClientDisconnected escape: the
    connection is over, which uvicorn does not log either. Nothing is
    sent to it."""
    h.job(0, "wsescape")
    h.settle()
    mark = len(h.events)
    h.disconnect(0)
    h.settle(passes=120)
    after = [e[0] for e in h.events[mark:] if len(e) > 1 and e[1] == 0]
    assert "stream_note" not in after, (
        "a client's departure was logged as an application error: %r"
        % (after,))
    assert "ws_close" not in after and "ws_send" not in after, after


# --- the whole-branch review's findings (2026-09-23) -----------------------
#
# Each of these reproduces a finding the review made against the first cut
# of L20-L24: C1 a socket that ends with NO disconnect tag (the loop tags only
# what is still subscribed, and an app's own close unsubscribes first), C2 a
# leftover task answering the slot's next request, I1 receive() after the
# response, I2 credit charged to a socket that has gone, I3 rules the suite
# did not pin, M4 the eager task factory. `Harness.disconnect()` always tags,
# which is how the first cut passed: these recycle the slot WITHOUT one.


def test_a_socket_the_app_closed_refuses_its_kept_send(h):
    """C1: nothing stamps a socket the APPLICATION closed -- the loop sees
    no subscription left when the connection ends -- so the socket's own
    record of its close is what must refuse a kept send once the slot has
    a new client. Modelled with no disconnect tag at all."""
    h.job(0, "wsclosehold")
    h.settle()
    assert "ws_close" in h.kinds(0), h.kinds(0)
    stale = h.ws_sends[0]
    h.job(0, "wskeep")          # the next client, with no tag in between
    h.settle()
    mark = len(h.events)
    result = h.run(h.foreign(stale, {"type": "websocket.send",
                                     "text": "for the first client"}))
    leaked = [e for e in h.events[mark:] if e[0] == "ws_send" and e[1] == 0]
    assert not leaked, (
        "a socket the app closed sent into the slot's next client: %r"
        % (leaked,))
    assert result != "returned", (
        "a send after the app's own close returned as if it went out")


def test_a_socket_the_app_closed_does_not_close_the_next_client(h):
    """C1: a socket whose app closed it and returned later ran its finally
    against the SLOT's accept -- the next client's -- and closed that
    client (measured live: the next client closed at +1.00 s)."""
    h.job(0, "wsclosewait")
    h.settle(passes=5)
    assert "ws_close" in h.kinds(0), h.kinds(0)
    h.job(0, "wskeep")
    h.settle(passes=120)
    kinds = h.kinds(0)
    assert kinds.count("ws_close") == 1 and "ws_reject" not in kinds, (
        "a closed socket's finally reached the slot's next client: %r"
        % (kinds,))


def test_a_second_close_is_not_a_rejection(h):
    """C1: a second close from an app used to fall through to `ws_reject`,
    which the loop answers by refusing whatever handshake holds the slot
    next with a 403."""
    h.job(0, "wsclosetwice")
    h.settle()
    kinds = h.kinds(0)
    assert kinds.count("ws_close") == 1 and "ws_reject" not in kinds, kinds


def test_a_receive_after_the_apps_own_close_is_a_disconnect(h):
    """C1: after its own close an app waits for the client's reply, which
    uvicorn delivers as websocket.disconnect. Nothing told the executor, so
    the wait was for ever: a Channels consumer that closes itself stayed in
    its groups for good."""
    h.job(0, "wscloserecv")
    h.settle()
    assert h.second_receive == ["websocket.disconnect"], (
        "a receive() after the app's own close did not end: %r"
        % (h.second_receive,))


def test_a_leftover_task_never_answers_the_slots_next_request(h):
    """C2: answering at the final body made `send` a completion site of its
    own, and it did not know the done-callback had already answered the
    job. A task the application left behind answered the SLOT'S NEXT
    request with its response -- another client's, live."""
    h.job(0, "leftover")
    h.settle(passes=5)
    h.job(0, "plain")
    h.settle(passes=80)
    answers = [e for e in h.events if e[0] in ("done", "err") and e[1] == 0]
    assert not [e for e in answers if e[0] == "done" and e[4] == b"LATE"], (
        "a leftover task's late answer reached the slot: %r" % (answers,))
    assert [e[0] for e in answers] == ["err", "done"], answers


def test_receive_after_the_response_is_a_disconnect(h):
    """I1: uvicorn answers a receive() after the response with
    http.disconnect at once. A buffered response gets no disconnect tag,
    so the wait was for the life of the process -- and held the shutdown
    drain to the join bound."""
    h.job(0, "bgreceive")
    h.settle()
    assert h.bg_receive == ["http.disconnect"], (
        "a receive() after the response did not answer: %r" % (h.bg_receive,))


def test_a_gone_socket_is_not_charged_for_the_credit_it_woke_to(h):
    """I2: an ack and the disconnect in one pass woke a waiting send with
    enough credit, and it charged the window before asking whether its
    socket had gone -- leaving those bytes in flight on the slot, which
    the next client now holds, until that client's own cleanup."""
    frame = h.ns["_ws_frame_bytes"](Harness.WS_FLOOD_SIZE)
    h.job(0, "wsflood")
    h.settle()
    h.ack(0, frame)
    h.disconnect(0)
    h.job(0, "wshold")
    h.settle()
    assert h.ns["_exec_inflight"].get(0, 0) == 0, (
        "%d bytes charged to a socket that had gone stay in flight on the "
        "slot" % h.ns["_exec_inflight"].get(0, 0))
    _assert_global_window_whole(h)


def test_a_gone_stream_is_not_charged_for_the_credit_it_woke_to(h):
    """I2, the stream half: a hub pushing to a held stream waits on the
    stream's credit from a task that is not the stream's, so nothing
    cancels it when the client goes."""
    window = h.ns["_ASGI_CREDIT_WINDOW"]
    h.job(0, "storehold")
    h.settle()
    stale = h.http_sends[0]
    piece = b"z" * (window // 2)

    async def push():
        for _ in range(3):
            await stale({"type": "http.response.body", "body": piece,
                         "more_body": True})
    pusher = h.loop.create_task(push())
    h.settle()
    assert not pusher.done(), "the pusher never had to wait for credit"
    h.ack(0, window // 2)
    h.disconnect(0)
    h.job(0, "wshold")
    h.settle()
    pusher.cancel()
    h.settle(passes=5)
    assert h.ns["_exec_inflight"].get(0, 0) == 0, (
        "%d bytes charged to a stream that had gone stay in flight on the "
        "slot" % h.ns["_exec_inflight"].get(0, 0))
    _assert_global_window_whole(h)


def test_a_finished_background_task_leaves_the_next_stream_alone(h):
    """I3: the completed branch of `_Cycle.done` cleans only as the slot's
    owner. Unowned, a keep-alive request's late finish pulled the NEXT
    request's credit window out from under its stream (KeyError: 0)."""
    h.job(0, "background")
    h.settle()
    h.job(0, "slow")
    h.settle(passes=2)
    h.release.set()
    h.settle()
    kinds = h.kinds(0)
    assert "stream_end" in kinds, kinds
    for bad in ("stream_note", "stream_abort", "err"):
        assert bad not in kinds, (
            "the first request's late finish broke the next one's stream: %r"
            % (kinds,))


def test_a_gone_streams_final_body_does_not_end_the_next_stream(h):
    """I3: a final body from a task whose client has gone -- here from a
    finally, after the disconnect cancelled it -- must not send an end
    frame: the slot may already be the next response's."""
    h.job(0, "finallyend")
    h.settle()
    mark = len(h.events)
    h.disconnect(0)
    h.job(0, "hold")
    h.settle()
    after = [e[0] for e in h.events[mark:] if len(e) > 1 and e[1] == 0]
    assert "stream_start" in after, after
    assert "stream_end" not in after, (
        "a gone stream's final body ended the slot's next stream: %r"
        % (after,))


def test_a_head_is_answered_at_its_first_streamed_body_and_never_streams(h):
    """L27: a HEAD's response is its head (RFC 9110 §9.3.2). A streaming
    application answers one as it answers a GET -- Starlette's
    StreamingResponse does -- and the executor switched it to streaming like
    any GET. The loop will not chunk a HEAD, so the body went to the wire
    raw after the head, 10,000 of 10,000 bytes measured, where a keep-alive
    connection's next response begins. It is answered at its first streamed
    body instead, with no body; the rest is dropped, and receive() then
    says the client has gone, which is what stops a StreamingResponse."""
    h.job(0, "headstream")
    h.settle()
    kinds = h.kinds(0)
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1 and done[0][2] == 200 and done[0][4] == b"", (
        "a HEAD was not answered once, with its head and no body: %r"
        % (kinds,))
    assert done[0][3] == [(b"content-type", b"text/plain")], done[0][3]
    assert not [k for k in kinds if k.startswith("stream")], (
        "a HEAD streamed: %r" % (kinds,))
    assert h.head_receive == ["http.disconnect"], h.head_receive
    assert h.head_finished, "the application's later sends did not return"
    _assert_global_window_whole(h)


def test_a_bodiless_status_is_answered_at_its_first_streamed_body(h):
    """A 1xx, 204 or 304 has no content at all (RFC 9110 §6.4.1), and the
    loop frames none of them, so one streamed went to the wire raw exactly
    as a HEAD's body did. The WSGI side has never streamed one
    (`_stream_this`); the executor answers it at its first streamed body
    too."""
    h.job(0, "stream204")
    h.settle()
    kinds = h.kinds(0)
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1 and done[0][2] == 204 and done[0][4] == b"", (
        "a streamed 204 was not answered once, with no body: %r" % (kinds,))
    assert not [k for k in kinds if k.startswith("stream")], (
        "a 204 streamed: %r" % (kinds,))
    assert h.head_finished, "the application's later sends did not return"
    _assert_global_window_whole(h)


def test_a_head_tells_a_listening_application_its_response_is_over(h):
    """A HEAD answered at its first streamed body is over for the loop, which
    saw an answer, not a stream, and so never sends a disconnect for it. A
    receive() parked from before that body -- Starlette's
    listen_for_disconnect under ASGI 2.3, Django's listener -- is what stops
    an endless StreamingResponse, and nothing woke it: the application ran
    for the life of the process, one task per HEAD, and held the shutdown
    drain open. The early answer wakes it with http.disconnect."""
    h.job(0, "headlisten")
    h.settle()
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1 and done[0][4] == b"", h.kinds(0)
    assert h.head_receive == ["http.disconnect"], (
        "the parked receive() was never told the response is over: %r"
        % (h.head_receive,))
    assert h.head_finished and h.head_task.done(), (
        "the application is still running after its HEAD was answered")
    assert not h.head_task.cancelled(), (
        "the listening application was cancelled, not told: its background "
        "work would not run")
    _assert_global_window_whole(h)


def test_a_head_stops_an_application_that_never_listens(h):
    """An application that never calls receive() cannot be told its HEAD
    was answered, and an endless body nobody reads ran for ever (asgi_bare's
    /stream-forever). Before the early answer, the client's close cancelled
    it as a stream; now it is cancelled once `_HEAD_GRACE` has passed."""
    h.ns["_HEAD_GRACE"] = 0.02
    h.job(0, "headforever")
    h.settle(passes=120)
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1 and done[0][4] == b"", h.kinds(0)
    assert h.head_task is not None and h.head_task.done(), (
        "an application that never listens is still producing its HEAD's body")
    _assert_global_window_whole(h)


def test_a_body_after_the_final_body_answers_nothing(h):
    """I3: once a response is answered, a further body has nothing to
    answer."""
    h.job(0, "twice")
    h.settle()
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1 and done[0][4] == b"first", done


def test_a_tight_producer_into_a_gone_stream_still_yields(h):
    """I3: a send into a gone stream is a no-op that YIELDS. A producer that
    loops on send with no other await would otherwise spin the executor
    thread, and its own cancellation could never land."""
    h.job(0, "storehold")
    h.settle()
    stale = h.http_sends[0]
    h.disconnect(0)
    h.settle()
    ran = [0]

    async def canary():
        while True:
            ran[0] += 1
            await asyncio.sleep(0)

    async def tight():
        c = asyncio.get_running_loop().create_task(canary())
        await asyncio.sleep(0)
        start = ran[0]
        for _ in range(50):
            await stale({"type": "http.response.body", "body": b"x",
                         "more_body": True})
        seen = ran[0] - start
        c.cancel()
        return seen
    seen = h.run(tight())
    assert seen > 0, (
        "fifty sends into a gone stream never yielded: a producer that "
        "loops on send would spin the executor")


def test_a_gone_requests_receive_says_so_at_once(h):
    """I3: a receive() on a request whose client has gone says so at once
    -- and never waits on the slot's disconnect future, which belongs to
    the slot's next request by then."""
    h.job(0, "storehold")
    h.settle()
    stale_receive = h.http_receives[0]
    h.disconnect(0)
    h.job(0, "hold")
    h.settle()

    async def twice():
        await stale_receive()       # the request body, never taken
        msg = await asyncio.wait_for(stale_receive(), 0.2)
        return msg["type"]
    assert h.run(twice()) == "http.disconnect"


def test_a_client_disconnect_after_the_response_is_not_logged(h):
    """I3: the client's departure escaping the app after its response was
    answered is not an application error."""
    h.job(0, "bgclientdisc")
    h.settle()
    assert "log" not in h.kinds(0), h.kinds(0)


def test_an_eager_task_factory_still_ends_its_stream(h):
    """M4: under asyncio.eager_task_factory the task runs its first step
    inside create_task, before `spawn` could record it; every "am I gone"
    then asked about None, and a streamed response never ended."""
    h.loop.set_task_factory(asyncio.eager_task_factory)
    h.job(0, "finish")
    h.settle()
    kinds = h.kinds(0)
    assert "stream_end" in kinds, kinds
    assert "stream_note" not in kinds and "err" not in kinds, kinds


def test_a_body_before_its_start_leaves_no_stray_bytes(h):
    """PR 1 review M5: a body sent before its start raises, and nothing of
    it may survive into the response an application that caught the error
    then sends properly. The chunk used to be appended before the check,
    so the answer went out as b'strayok'."""
    h.job(0, "bodyfirst")
    h.settle()
    done = [e for e in h.events if e[0] == "done" and e[1] == 0]
    assert len(done) == 1, h.kinds(0)
    assert done[0][4] == b"ok", done[0][4]


def _linger_then(h, successor):
    """A stream on slot 0 lingers past its disconnect (one cancel, which it
    swallows); `successor` is spawned on the recycled slot and then its own
    connection leaves. Returns the cancels the lingering task saw."""
    h.job(0, "linger")
    h.settle()
    assert h.kinds(0)[:1] == ["stream_start"], h.kinds(0)
    h.disconnect(0)
    h.settle()
    assert h.linger_cancels == 1, h.linger_cancels
    h.job(0, successor)
    h.settle()
    h.disconnect(0)
    h.settle()
    return h.linger_cancels


def test_a_websocket_spawn_forgets_the_previous_connections_stream_task(h):
    """PR 1 review M3: a socket spawned on a slot whose previous stream task
    is still winding down must not cancel that task again when the socket's
    own client leaves. The slot's stream-task entry named the old task, and
    only its owner's cleanup removed it. The socket must still be open when
    its client leaves: one that returns at once cleans the slot first."""
    assert _linger_then(h, "wskeep") == 1, h.linger_cancels


def test_an_http_spawn_forgets_the_previous_connections_stream_task(h):
    """The HTTP twin of M3: a request parked in receive() on the recycled
    slot leaves, and the previous connection's stream task is not cancelled
    a second time."""
    assert _linger_then(h, "longpoll") == 1, h.linger_cancels


def test_the_drain_ends_an_http_task_that_never_ends(h):
    """PR 3 review: the post-pill gather bounded sockets only, so an HTTP
    task that never ends -- background work after its response -- held
    run_forever open until the thread join gave up, and lifespan shutdown
    never ran. Past the grace every task is cancelled; work that finishes
    inside it is left to finish."""
    h.ns["_WS_DRAIN_GRACE"] = 0.02
    h.ns["_HTTP_DRAIN_GRACE"] = 0.2
    h.job(0, "forever")
    h.job(1, "slowbg")
    h.settle()
    assert [e for e in h.events if e[0] == "done" and e[1] == 0], h.kinds(0)
    h.run(asyncio.wait_for(h.ns["_gather_in_flight"](), 2.0))
    assert h.forever_ended, "the endless task was not ended"
    assert h.slowbg_done, "work inside the grace was cut short"
    assert not h.ns["_exec_tasks"], h.ns["_exec_tasks"]


def test_an_error_is_described_once(h):
    """PR 1 review M6: the log's description led with the one-line summary
    and then the traceback, whose last line is the same summary."""
    try:
        raise ValueError("kaboom")
    except ValueError as exc:
        text = h.ns["_describe"](exc)
    lines = text.splitlines()
    assert lines[0] == "ValueError: kaboom", lines[:1]
    assert lines.count("ValueError: kaboom") == 1, text
    assert any(l.startswith("Traceback") for l in lines), text


def test_a_wsgi_head_answers_at_its_first_item_and_closes_the_body(h):
    """K13, L27's WSGI twin: a HEAD to a lazily produced body, on a pool
    thread that would stream its GET, is answered at the body's first item
    with no length, and the body is closed -- its `finally` runs. HEAD used
    to take the buffered path and join the whole iterable: for a body that
    never ends, never. Bounded here (1000 items) so the old path fails
    rather than hangs."""
    produced, closed = [0], []

    class Endless:
        # An iterable with its own close(), held by the test: generator
        # finalization cannot stand in for the call PEP 3333 requires.
        def __iter__(self):
            for _ in range(1000):
                produced[0] += 1
                yield b"data: tick\n\n"

        def close(self):
            closed.append(True)

    body_obj = Endless()

    def app(environ, start_response):
        start_response("200 OK", [("Content-Type", "text/event-stream")])
        return body_obj

    saved = h.ns["_app"]
    h.ns["_app"] = app
    h.ns["set_stream_capable"](True)
    try:
        status, headers, body, streaming = h.ns["_run_wsgi"](
            {"REQUEST_METHOD": "HEAD"}, b"")
    finally:
        h.ns["set_stream_capable"](False)
        h.ns["_app"] = saved
    assert produced[0] == 1, "the HEAD drained %d items" % produced[0]
    assert closed == [True], "the body was not closed"
    assert body == b"" and streaming is False, (body[:40], streaming)
    assert status == "200 OK", status
    assert not any(n.lower() == "content-length" for n, _ in headers), headers


def test_a_socket_hears_its_clients_close_code(h):
    """L28: the disconnect a socket's application hears carries the code its
    client closed with, when the loop parsed one. It was 1006 for every
    disconnect, where uvicorn passes the client's own (1001 for a tab closed,
    1000 for a clean close)."""
    h.job(0, "wsexcept")
    h.settle()
    h.disconnect(0, 1001)
    h.settle()
    assert h.cleanups == [1001], h.cleanups


def _logs(h, text):
    return [e for e in h.events if e[0] == "log" and text in e[2]]


def test_background_work_inside_the_grace_finishes(h):
    """Review focus 1: background work still running when the drain begins,
    and finishing inside its grace, is left to finish -- neither cancelled
    with the sockets at _WS_DRAIN_GRACE nor at the pill."""
    h.ns["_WS_DRAIN_GRACE"] = 0.02
    h.ns["_HTTP_DRAIN_GRACE"] = 0.6
    h.job(0, "latebg")
    h.settle()
    gather = h.loop.create_task(h.ns["_gather_in_flight"]())
    h.loop.call_later(0.1, h.release.set)
    h.run(asyncio.wait_for(gather, 3.0))
    assert h.latebg_done, "background work inside the grace was cut short"
    assert not _logs(h, "cancelled"), _logs(h, "cancelled")


def test_a_task_that_swallows_its_cancellation_does_not_hold_the_drain(h):
    """Review focus 2: a task that catches its CancelledError and keeps going
    is waited on for _CANCEL_GRACE after its cancellation, then left behind
    and named -- never waited on for as long as it runs."""
    h.ns["_WS_DRAIN_GRACE"] = 0.01
    h.ns["_HTTP_DRAIN_GRACE"] = 0.05
    h.ns["_CANCEL_GRACE"] = 0.05
    h.job(0, "swallow")
    h.settle()
    h.run(asyncio.wait_for(h.ns["_gather_in_flight"](), 3.0))
    assert len(_logs(h, "cancelled 1 task")) == 1, h.events[-3:]
    assert len(_logs(h, "still running after their cancellation")) == 1, h.events[-3:]


def test_a_task_left_behind_never_reaches_the_port(h):
    """PR 6 review C1: once the drain has stopped the loop the Mojo side frees
    its executor state, and lifespan shutdown steps this loop again -- so a
    task the drain left behind that answered then wrote into freed memory
    (a segmentation fault, 3 of 3). Nothing reaches the port after the stop."""
    h.ns["_WS_DRAIN_GRACE"] = 0.01
    h.ns["_HTTP_DRAIN_GRACE"] = 0.05
    h.ns["_CANCEL_GRACE"] = 0.05
    h.job(0, "swallowlate")
    h.settle()
    h.pill()
    assert h.run_until_stopped(3.0), "the drain never stopped the loop"
    mark = len(h.events)
    h.settle(passes=400)    # lifespan shutdown's turn: the task answers now
    late = [e for e in h.events[mark:] if len(e) > 1 and e[1] == 0]
    assert not late, "a task left behind reached the port: %r" % (late,)


def test_the_drain_runs_once(h):
    """PR 6 review I2: a pill can arrive twice -- macOS reports the lane's
    close after it as a second -- and two drains, each ending on its own
    timer, let the later one stop the loop inside lifespan shutdown."""
    h.ns["_WS_DRAIN_GRACE"] = 0.01
    h.ns["_HTTP_DRAIN_GRACE"] = 0.05
    h.ns["_CANCEL_GRACE"] = 0.05
    h.job(0, "swallow")
    h.settle()
    h.pill()
    h.submit_w.close()
    assert h.run_until_stopped(3.0), "the drain never stopped the loop"
    assert len(_logs(h, "cancelled 1 task")) == 1, [e for e in h.events if e[0] == "log"]


def test_an_eager_stream_is_still_cancelled_at_its_disconnect(h):
    """PR 6 review I3: under an eager task factory the task's first step --
    which registers its stream -- runs inside create_task, so a pop of the
    slot's stream-task entry AFTER create_task took the live stream's own
    entry, and its disconnect cancelled nothing."""
    h.loop.set_task_factory(asyncio.eager_task_factory)
    h.job(0, "bytes1024")
    h.settle()
    assert h.kinds(0)[:1] == ["stream_start"], h.kinds(0)
    task = h.ns["_exec_slot_task"][0]
    h.disconnect(0)
    h.settle()
    assert task.done(), "the stream's task was not cancelled at its disconnect"


def test_an_application_error_is_described_once(h):
    """PR 6 review M6: an application's exception class is qualified by its
    module in the traceback's last line, and a note follows it; neither is
    said twice."""
    cls = type("PaymentFailed", (Exception,), {"__module__": "myapp.errors"})
    # Built at run time: the traceback quotes this file's source lines, and
    # a literal there would be counted too.
    msg, note = "card " + "declined", "while " + "charging"
    try:
        raise cls(msg)
    except Exception as exc:
        exc.add_note(note)
        text = h.ns["_describe"](exc)
    assert text.count("card declined") == 1, text
    assert text.count("while charging") == 1, text


def test_a_wsgi_head_to_a_body_that_produces_nothing_measures_write(h):
    """PR 6 review M7: a lazy body that yields only empty chunks is the GET's
    buffered case, with a measured length of what write() produced; its
    HEAD returns the same bytes for the gateway to measure."""
    def app(environ, start_response):
        write = start_response("200 OK", [("Content-Type", "text/plain")])
        write(b"written-body")

        def gen():
            yield b""
            yield b""
        return gen()

    saved = h.ns["_app"]
    h.ns["_app"] = app
    h.ns["set_stream_capable"](True)
    try:
        _, _, body, streaming = h.ns["_run_wsgi"]({"REQUEST_METHOD": "HEAD"}, b"")
    finally:
        h.ns["set_stream_capable"](False)
        h.ns["_app"] = saved
    assert body == b"written-body" and streaming is False, (body, streaming)


def test_work_scheduled_at_import_is_refused_by_name(h):
    """L26: a module that calls asyncio.create_task at import cannot load --
    m0serve imports an application outside any running loop, as uvicorn does
    without --reload -- and the load failure names what the module did and
    the fix. Any OTHER RuntimeError keeps its own words: the name is for
    asyncio's "no loop" only."""
    import importlib
    import tempfile
    import warnings

    names = ("m0_probe_import_task", "m0_probe_import_other")
    sources = (
        "import asyncio\n"
        "async def _tick():\n"
        "    pass\n"
        "_t = asyncio.create_task(_tick())\n"
        "app = None\n",
        "raise RuntimeError('database is locked')\n",
    )
    with tempfile.TemporaryDirectory() as tmp:
        for name, text in zip(names, sources):
            with open(os.path.join(tmp, name + ".py"), "w") as f:
                f.write(text)
        sys.path.insert(0, tmp)
        importlib.invalidate_caches()
        got = []
        try:
            # The coroutine create_task was handed is never awaited, which
            # is the point; its RuntimeWarning is not this test's output --
            # and the filter is scoped, so later tests keep their warnings.
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", RuntimeWarning)
                for name in names:
                    try:
                        h.ns["detect_spec"](name, "app")
                    except RuntimeError as e:
                        got.append(str(e))
                    else:
                        got.append(None)
        finally:
            sys.path.remove(tmp)
            for name in names:
                sys.modules.pop(name, None)
    named, other = got
    assert named is not None, "a module that create_task'd at import loaded"
    assert "scheduled asyncio work at import" in named, named
    # The fix named must exist in the framework it is named for: Starlette
    # 1.x has no on_startup (only lifespan=); FastHTML still takes both.
    assert "FastHTML: on_startup=[...] or lifespan=..." in named, named
    assert "Starlette and FastAPI: lifespan=..." in named, named
    assert "Starlette and FastHTML" not in named, named
    assert "Traceback (most recent call last)" in named, named
    assert other is not None and "database is locked" in other, other
    assert "scheduled asyncio work" not in other, other


TESTS = [
    test_a_stale_task_does_not_wipe_its_successors_slot_state,
    test_a_finished_owner_does_clean_its_slot,
    test_a_lingering_task_does_not_end_its_successors_stream,
    test_a_successor_does_not_inherit_its_predecessors_disconnect,
    test_a_stale_ack_cannot_inflate_the_successors_window,
    test_a_websocket_successor_does_not_inherit_its_predecessors_disconnect,
    test_a_websocket_recycle_forgets_the_predecessors_accept,
    test_a_websocket_send_waits_for_its_window,
    test_a_stream_sent_from_a_child_task_marks_the_owner,
    test_a_gone_sockets_hook_can_send_to_the_others,
    test_a_stale_socket_send_never_reaches_the_slots_next_client,
    test_a_send_from_a_finished_socket_is_refused,
    test_a_stale_stream_send_never_reaches_the_slots_next_response,
    test_a_socket_disconnect_reaches_the_app_through_receive,
    test_a_receive_after_the_disconnect_says_so_again,
    test_the_drain_ends_a_socket_blocked_outside_receive,
    test_a_response_is_answered_at_its_final_body,
    test_a_stream_ends_at_its_final_body,
    test_an_error_after_the_final_body_keeps_the_apps_response,
    test_an_error_before_the_response_is_logged_with_its_traceback,
    test_a_late_error_is_logged_with_its_traceback,
    test_a_socket_whose_app_raises_closes_with_1011,
    test_a_disconnect_that_escapes_the_app_is_not_an_error,
    test_a_socket_the_app_closed_refuses_its_kept_send,
    test_a_socket_the_app_closed_does_not_close_the_next_client,
    test_a_second_close_is_not_a_rejection,
    test_a_receive_after_the_apps_own_close_is_a_disconnect,
    test_a_leftover_task_never_answers_the_slots_next_request,
    test_receive_after_the_response_is_a_disconnect,
    test_a_gone_socket_is_not_charged_for_the_credit_it_woke_to,
    test_a_gone_stream_is_not_charged_for_the_credit_it_woke_to,
    test_a_finished_background_task_leaves_the_next_stream_alone,
    test_a_gone_streams_final_body_does_not_end_the_next_stream,
    test_a_body_after_the_final_body_answers_nothing,
    test_a_head_is_answered_at_its_first_streamed_body_and_never_streams,
    test_a_bodiless_status_is_answered_at_its_first_streamed_body,
    test_a_head_tells_a_listening_application_its_response_is_over,
    test_a_head_stops_an_application_that_never_listens,
    test_a_tight_producer_into_a_gone_stream_still_yields,
    test_a_gone_requests_receive_says_so_at_once,
    test_a_client_disconnect_after_the_response_is_not_logged,
    test_an_eager_task_factory_still_ends_its_stream,
    test_work_scheduled_at_import_is_refused_by_name,
    test_a_body_before_its_start_leaves_no_stray_bytes,
    test_a_websocket_spawn_forgets_the_previous_connections_stream_task,
    test_an_http_spawn_forgets_the_previous_connections_stream_task,
    test_the_drain_ends_an_http_task_that_never_ends,
    test_an_error_is_described_once,
    test_a_wsgi_head_answers_at_its_first_item_and_closes_the_body,
    test_a_socket_hears_its_clients_close_code,
    test_background_work_inside_the_grace_finishes,
    test_a_task_that_swallows_its_cancellation_does_not_hold_the_drain,
    test_a_task_left_behind_never_reaches_the_port,
    test_the_drain_runs_once,
    test_an_eager_stream_is_still_cancelled_at_its_disconnect,
    test_an_application_error_is_described_once,
    test_a_wsgi_head_to_a_body_that_produces_nothing_measures_write,
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
        "a send is judged by the calling task, not the connection's",
        "    return getattr(owner, '_m0_disconnected', False) or owner.done()",
        "    import asyncio\n\n"
        "    return getattr(asyncio.current_task(), '_m0_disconnected', False)",
    ),
    (
        "a finished connection is not gone",
        "    return getattr(owner, '_m0_disconnected', False) or owner.done()",
        "    return getattr(owner, '_m0_disconnected', False)",
    ),
    (
        "a send to a gone socket returns quietly",
        "            raise ClientDisconnected()\n"
        "        if closed[0]:",
        "            return\n"
        "        if closed[0]:",
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
        "websocket.send is not credit-gated",
        "            await _ws_spend(slot, owner, _ws_frame_bytes(len(payload)))\n"
        "            if _task_gone(owner):\n"
        "                raise ClientDisconnected()\n"
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
        "a disconnect cancels the socket's task",
        "    task._m0_ws = True\n",
        "    task._m0_ws = True\n    _exec_stream_tasks[slot] = task\n",
    ),
    (
        "a receive after the disconnect waits",
        "        if ended[0] is not None:\n",
        "        if False:\n",
    ),
    (
        "the drain waits for every socket",
        "        if getattr(t, '_m0_ws', False):\n            t.cancel()\n",
        "        pass\n",
    ),
    (
        "a response is answered when the application returns",
        "            self.completed = True\n"
        "            body, self.chunks = b''.join(self.chunks), []\n"
        "            _exec_put(('done', self.slot, self.status, self.headers, body))",
        "            return",
    ),
    (
        "a stream is ended when the application returns",
        "                    if not _task_gone(self.task):\n"
        "                        _exec_put(('stream_end', self.slot))\n"
        "                return",
        "                    self.completed = False\n"
        "                return",
    ),
    (
        "an ended stream stays cancellable",
        "                        _exec_stream_tasks.pop(self.slot, None)\n",
        "                        pass\n",
    ),
    (
        "the log gets the exception's name only",
        "    return head + '\\n' + '\\n'.join(lines)",
        "    return head",
    ),
    (
        "an application error closes the socket with 1000",
        "                _exec_put(('ws_close', slot, 1011 if failed else 1000))",
        "                _exec_put(('ws_close', slot, 1000))",
    ),
    (
        "a client's departure is logged as an application error",
        "            if exc is not None and not isinstance(exc, ClientDisconnected):\n"
        "                _exec_put(('stream_note', slot, _describe(exc)))",
        "            if exc is not None:\n"
        "                _exec_put(('stream_note', slot, _describe(exc)))",
    ),
    (
        "a socket's own close does not end what it may send",
        "        if closed[0]:\n"
        "            # This socket's own close has gone out: nothing more may.",
        "        if False:\n"
        "            # This socket's own close has gone out: nothing more may.",
    ),
    (
        "a socket's finally closes a socket it already closed",
        "            if accepted[0] and not closed[0]:",
        "            if accepted[0]:",
    ),
    (
        "a socket's own close does not end its receive()",
        "            if ended[0] is None:\n"
        "                ended[0] = {\n"
        "                    'type': 'websocket.disconnect',",
        "            if False:\n"
        "                ended[0] = {\n"
        "                    'type': 'websocket.disconnect',",
    ),
    (
        "a send after the response is over still answers",
        "        if self.completed or self.task.done():\n"
        "            # The response is over",
        "        if self.completed:\n"
        "            # The response is over",
    ),
    (
        "a body after the final body answers again",
        "        if self.completed or self.task.done():\n"
        "            # The response is over",
        "        if self.task.done():\n"
        "            # The response is over",
    ),
    (
        "a receive after the response waits",
        "        if self.completed or _task_gone(self.task):\n"
        "            # Answered, or gone",
        "        if _task_gone(self.task):\n"
        "            # Answered, or gone",
    ),
    (
        "a gone request's receive waits on the slot's future",
        "        if self.completed or _task_gone(self.task):\n"
        "            # Answered, or gone",
        "        if self.completed:\n"
        "            # Answered, or gone",
    ),
    (
        "a socket is charged for credit after it has gone",
        "    if _task_gone(owner):\n"
        "        raise ClientDisconnected()\n"
        "    _exec_credits[slot] -= nbytes",
        "    _exec_credits[slot] -= nbytes",
    ),
    (
        "a stream is charged for credit after it has gone",
        "            if _task_gone(owner):\n"
        "                # Woken by an ack and a disconnect in the same pass",
        "            if False:\n"
        "                # Woken by an ack and a disconnect in the same pass",
    ),
    (
        "a finished background task cleans whatever the slot holds",
        "        if _exec_slot_task.get(self.slot) is t:",
        "        if True:",
    ),
    (
        "a gone stream's final body still ends the stream",
        "                    if not _task_gone(self.task):\n"
        "                        _exec_put(('stream_end', self.slot))",
        "                    if True:\n"
        "                        _exec_put(('stream_end', self.slot))",
    ),
    (
        "a dropped send does not yield",
        "    # land.\n"
        "    import asyncio\n"
        "\n"
        "    await asyncio.sleep(0)",
        "    # land.\n"
        "    return",
    ),
    (
        "a client's departure after the response is logged",
        "            if exc is not None and not isinstance(exc, ClientDisconnected):\n"
        "                _exec_put(\n"
        "                    (\n"
        "                        'log',",
        "            if exc is not None:\n"
        "                _exec_put(\n"
        "                    (\n"
        "                        'log',",
    ),
    (
        "the task is recorded only by spawn",
        "        if self.task is None:\n"
        "            # asyncio.eager_task_factory",
        "        if False:\n"
        "            # asyncio.eager_task_factory",
    ),
    (
        "a drain ack is added rather than clamped to the window",
        "                credited = _exec_credits[slot] + n\n"
        "                if credited > _ASGI_CREDIT_WINDOW:\n"
        "                    credited = _ASGI_CREDIT_WINDOW\n"
        "                _exec_credits[slot] = credited",
        "                _exec_credits[slot] += n",
    ),
    (
        "a HEAD streams like a GET",
        "                if self.head or self.status < 200 or self.status in (204, 304):",
        "                if self.status < 200 or self.status in (204, 304):",
    ),
    (
        "a status with no content streams",
        "                if self.head or self.status < 200 or self.status in (204, 304):",
        "                if self.head:",
    ),
    (
        "a receive() parked before a HEAD's early answer is never woken",
        "                    if fut is not None and not fut.done():\n"
        "                        fut.set_result(True)\n"
        "                    else:\n",
        "                    if False:\n"
        "                        pass\n"
        "                    else:\n",
    ),
    (
        "a HEAD's application that never listens is never stopped",
        "                        _loop.call_later(_HEAD_GRACE, self._stop_unheard)",
        "                        pass",
    ),
    (
        "a body before its start is kept before it is refused",
        "            if self.status is None:\n"
        "                raise RuntimeError(\n"
        "                    'ASGI sent http.response.body before http.response.start'\n"
        "                )\n"
        "            if chunk:\n"
        "                self.chunks.append(chunk)\n",
        "            if chunk:\n"
        "                self.chunks.append(chunk)\n"
        "            if self.status is None:\n"
        "                raise RuntimeError(\n"
        "                    'ASGI sent http.response.body before http.response.start'\n"
        "                )\n"
        "            if False:\n"
        "                self.chunks.append(chunk)\n",
    ),
    (
        "an HTTP spawn keeps the previous connection's stream task",
        "    _exec_stream_tasks.pop(slot, None)\n"
        "    cycle = _Cycle(slot, body)\n",
        "    cycle = _Cycle(slot, body)\n",
    ),
    (
        "a WebSocket spawn keeps the previous connection's stream task",
        "    # socket's to cancel when its client leaves (PR 1 review M3).\n"
        "    _exec_stream_tasks.pop(slot, None)\n",
        "    # socket's to cancel when its client leaves (PR 1 review M3).\n",
    ),
    (
        "the drain waits on an HTTP task for ever",
        "        for t in pending:\n"
        "            t.cancel()\n"
        "        if pending:\n",
        "        for t in pending:\n"
        "            pass\n"
        "        if pending:\n",
    ),
    (
        "an error's summary is said twice",
        "    if end >= len(summary) and lines[end - len(summary):end] == summary:\n",
        "    if False:\n",
    ),
    (
        "a WSGI HEAD joins its whole body",
        "        and environ.get('REQUEST_METHOD') == 'HEAD'\n"
        "        and _lazily_produced(",
        "        and False\n"
        "        and _lazily_produced(",
    ),
    (
        "a disconnect's close code is dropped",
        "                    int.from_bytes(data[9:11], 'little') if len(data) == 11 else 0,\n",
        "                    0,\n",
    ),
    (
        "the drain starts twice",
        "    if stopping and not _exec_draining[0]:\n",
        "    if stopping:\n",
    ),
    (
        "a task left behind reaches the port",
        "    if _exec_closed[0]:\n"
        "        return\n"
        "    stopping = _port.dispatch(ev)\n",
        "    stopping = _port.dispatch(ev)\n",
    ),
    (
        "background work is cancelled at the pill",
        "            rest, timeout=max(0.0, _HTTP_DRAIN_GRACE - _WS_DRAIN_GRACE)\n",
        "            rest, timeout=0\n",
    ),
    (
        "background work is cancelled with the sockets",
        "        if getattr(t, '_m0_ws', False):\n"
        "            t.cancel()\n"
        "    rest = ",
        "        t.cancel()\n"
        "    rest = ",
    ),
    (
        "a cancelled task is waited on for as long as it runs",
        "            _, stuck = await asyncio.wait(pending, timeout=_CANCEL_GRACE)\n",
        "            await asyncio.gather(*pending, return_exceptions=True)\n"
        "            stuck = ()\n",
    ),
    (
        "an eager stream's own entry is dropped at its spawn",
        "    _exec_stream_tasks.pop(slot, None)\n"
        "    cycle = _Cycle(slot, body)\n"
        "    task = _loop.create_task(cycle.run(scope))\n",
        "    cycle = _Cycle(slot, body)\n"
        "    task = _loop.create_task(cycle.run(scope))\n"
        "    _exec_stream_tasks.pop(slot, None)\n",
    ),
    (
        "a WSGI HEAD's body is never closed",
        "                close()\n"
        "        # A body that produced nothing",
        "                pass\n"
        "        # A body that produced nothing",
    ),
    (
        "a HEAD to a body that produced nothing drops write()",
        "        _body = b'' if produced else b''.join(written)\n",
        "        _body = b''\n",
    ),
    (
        "work scheduled at import is not named",
        "    if isinstance(e, RuntimeError) and str(e).startswith(_NO_LOOP):",
        "    if False:",
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
