"""Datastar todos — the flagship: live multi-tab sync, persisted in SQLite.

Where `apps/datastar_counter` broadcasts a signal (a number), this broadcasts
*HTML*: every mutation renders the `<section id="todos">` fragment once and
`patch_elements` morphs it into every connected tab. The list lives on the
server; the browser never owns state beyond the draft input.

The list also survives the server: todos are rows in SQLite (`M0_DB`, default
`todos.db`), so a restart comes back with the same list — the first example
composing `m0-sqlite` with the server. And so does the *stream*: every
broadcast frame is logged to the `events` table, restored into the
`DatastarStream` journal at boot (which seeds the event-id counter, keeping
ids monotonic across restarts), so a tab reconnecting with `Last-Event-ID`
after a restart is caught up from where it left off instead of waiting for
the next mutation. `apps/` is where packages compose; `m0-sqlite` itself
still imports nothing else here.

It also composes the framework layer the counter skips: the per-item actions
are `Router` routes with `:id` captures, each pattern a value in
`routes.mojo` that the renderer reverses with `url_for` —

    GET  /              the page, list already rendered
    GET  /events        opens the SSE stream (data-init)
    POST /add           reads the draft signal, inserts, broadcasts
    POST /toggle/:id    flips done, broadcasts
    POST /delete/:id    removes, broadcasts

The list fragment is a `Fragment[Datastar]` (page.mojo): the same
renderer whose output is the page's initial list is what every broadcast
carries, and `smoke-todo` greps it out of a live stream's frame.

It runs on the Mojo host (`m0_host.host`), so `M0_WORKERS=2` serves it
from two processes over one SQLite file (WAL mode). Each worker opens its own
connection, restores the same journal and joins the stream to the bus, and a
mutation on either reaches every tab. One rule makes that correct rather than
merely working: **a mutation holds SQLite's write lock from its change until
its frame is published** (`BEGIN IMMEDIATE` ... `COMMIT`). A frame is the
whole list, rendered and then numbered, and the tab keeps the newest number.
Without the lock, a worker could render before another worker's change
committed and still take the newer number, and every tab would show a list
missing that change until the next mutation. With it, the renders are
serialized across processes in the same order as their ids. `/events` and
`/health` name their worker in `x-worker`.

`M0_TODO_RENDER_PAUSE_MS` sleeps that long between rendering the list and
numbering its frame. It is the gate's knob, as `M0_SIM_ON_LOOP` is
`sim_loop`'s: the race the lock closes lasts microseconds, so without a
wider window no run can show that the lock is what closes it.

Because this app links libsqlite3, it is built and run, never `mojo run`:
the JIT resolves symbols only from libraries already in its process, which
happens to work on macOS and fails on Linux. `poe serve-todo` does the right
thing.

Run it:  uv run poe serve-todo
"""

from std.os import getenv
from std.time import sleep

from lightbug_http import HTTPRequest, HTTPResponse, OK
from lightbug_http.header import Headers, Header, HeaderKey
from m0_host.host import AppHandler, HostContext, serve

from m0_core.json_parse import parse_json_field

from m0_http import reply
from m0_http import AppConfig, Router, form, url_for

from m0_datastar.stream import DatastarStream
from m0_datastar.signals import read_signals

from m0_sqlite import Connection, open

from datastar_todo.page import render_page, render_todos
from datastar_todo.routes import ADD, DELETE, EDIT, EVENTS, TOGGLE


comptime STREAM_URL = EVENTS

# How many broadcast frames survive for replay — both the DatastarStream
# journal and the SQLite `events` table are pruned to this depth. A client
# further behind than this reconnects past the gap: it resumes live and its
# next mutation (or refresh) re-renders the full list anyway.
comptime JOURNAL_ENTRIES = 64

comptime H_ADD = 0
comptime H_TOGGLE = 1
comptime H_DELETE = 2
comptime H_EDIT = 3


struct TodoHandler(AppHandler):
    """One shared todo list, every connected tab in sync, rows in SQLite."""

    var router: Router
    var stream: DatastarStream
    var worker: Int
    var render_pause_s: Float64
    # The store is the database; every render loads fresh rows. Statements
    # are prepared per use — a statement cache was measured within noise for
    # this repo (docs/SQLITE_PERFORMANCE.md) and is deliberately absent.
    var db: Connection

    def __init__(out self, var db: Connection, capacity: Int, worker: Int) raises:
        self.router = Router()
        self.router.add("POST", ADD, H_ADD)
        self.router.add("POST", TOGGLE, H_TOGGLE)
        self.router.add("POST", DELETE, H_DELETE)
        self.router.add("POST", EDIT, H_EDIT)
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.stream = DatastarStream(capacity, journal_entries=JOURNAL_ENTRIES)
        self.worker = worker
        self.render_pause_s = 0.0
        var pause = getenv("M0_TODO_RENDER_PAUSE_MS", "")
        if pause.byte_length() > 0:
            self.render_pause_s = Float64(atol(pause)) / 1000.0
        # AUTOINCREMENT keeps ids never-reused across deletes and restarts,
        # matching what the in-memory version promised. `ORDER BY id` below
        # is what preserves insertion order — the visible order of the list.
        #
        # Inside an IMMEDIATE transaction, because two workers build their
        # handlers at once over one fresh file: `CREATE TABLE IF NOT EXISTS`
        # reads the schema first and upgrades to a write, and SQLite answers
        # that upgrade with "database is locked" at once rather than through
        # the busy handler, which cannot help a read that would have to be
        # redone (m0-sqlite's `busy_timeout` says so). Taking the write lock
        # up front waits instead. The race that was MEASURED at two workers
        # -- 29 of 30 starts refused -- was one step earlier, inside
        # `open()`'s WAL pragma, and is m0-sqlite's to retry (O1); the host
        # used to crash the losing worker and respawn it, which hid both
        # (SPEC E25).
        db.begin_immediate()
        db.execute(
            "CREATE TABLE IF NOT EXISTS todos ("
            "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "  text TEXT NOT NULL,"
            "  done INTEGER NOT NULL DEFAULT 0)"
        )
        # The broadcast log: the exact SSE frame bytes that went out under
        # each event id. Restored into the stream's journal at boot, which
        # also seeds the id counter — the two halves of SSE replay across
        # restarts (ids must stay monotonic, or Last-Event-ID means nothing
        # to the next process).
        db.execute(
            "CREATE TABLE IF NOT EXISTS events ("
            "  id INTEGER PRIMARY KEY,"
            "  url TEXT NOT NULL,"
            "  frame BLOB NOT NULL)"
        )
        db.commit()
        var saved = db.prepare("SELECT id, url, frame FROM events ORDER BY id")
        while saved.step():
            self.stream.restore(
                saved.column_text(1), saved.column_int(0), saved.column_blob(2)
            )
        self.db = db^

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        var handler = TodoHandler(
            open(getenv("M0_DB", "todos.db")), ctx.capacity, ctx.worker
        )
        # After the restore above: joining seeds the shared id counter from
        # the journal, so every worker numbers on from the last persisted id.
        handler.stream.enable_bus(ctx.bus, ctx.worker, ctx.id_addr)
        return handler^

    def _commit(mut self) raises:
        """Broadcast the list as it now stands, then release the write lock.

        In that order: the next writer, in this process or another, waits on
        the lock, so its render sees this change and its frame takes a newer
        id than this one.
        """
        self._broadcast()
        self.db.commit()

    def _abandon(mut self):
        """Roll back a mutation that raised, so the lock is not held on."""
        try:
            self.db.rollback()
        except:
            pass

    def _load(
        self,
    ) raises -> Tuple[List[Int], List[String], List[Bool]]:
        """Rows → the three parallel lists the renderer takes."""
        var ids = List[Int]()
        var texts = List[String]()
        var done = List[Bool]()
        var q = self.db.prepare("SELECT id, text, done FROM todos ORDER BY id")
        while q.step():
            ids.append(q.column_int(0))
            texts.append(q.column_text(1))
            done.append(q.column_int(2) != 0)
        return (ids^, texts^, done^)

    def _broadcast(mut self):
        """Render the fragment once, morph it into every subscriber.

        Also persists the broadcast frame to the `events` log so a client
        reconnecting after a restart can be caught up from its Last-Event-ID.
        """
        try:
            var rows = self._load()
            var fragment = render_todos(rows[0], rows[1], rows[2])
            if self.render_pause_s > 0:
                sleep(self.render_pause_s)
            var eid = self.stream.patch_elements(STREAM_URL, fragment)
            var ins = self.db.prepare(
                "INSERT OR REPLACE INTO events (id, url, frame)"
                " VALUES (?, ?, ?)"
            )
            ins.bind_int(1, eid)
            ins.bind_text(2, STREAM_URL)
            ins.bind_blob(3, self.stream.frame_for(eid))
            _ = ins.step()
            var prune = self.db.prepare("DELETE FROM events WHERE id <= ?")
            prune.bind_int(1, eid - JOURNAL_ENTRIES)
            _ = prune.step()
        except:
            pass  # a render bug must not kill the mutating request

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            var ok = OK('{"status":"ok"}', "application/json")
            ok.headers["x-worker"] = String(self.worker)
            return ok^

        if path == "/":
            var rows = self._load()
            return reply.html(render_page(rows[0], rows[1], rows[2]))

        if path == STREAM_URL:
            var resp = self.stream.open(req, STREAM_URL)
            resp.headers["x-worker"] = String(self.worker)
            return resp^

        var m = self.router.match(req.method, path)
        if not m.matched:
            return reply.json(404, String("Not Found"), String('{"error":"not found"}'))

        if m.handler_id == H_ADD:
            # The browser posts its signal store; the draft is all we want.
            var draft = parse_json_field(read_signals(req), "draft")
            if draft.byte_length() > 0:
                self.db.begin_immediate()
                try:
                    var ins = self.db.prepare(
                        "INSERT INTO todos (text) VALUES (?)"
                    )
                    ins.bind_text(1, draft)
                    _ = ins.step()
                    self._commit()
                except e:
                    self._abandon()
                    raise e^
            # Empty drafts are ignored, not an error: the Add button is
            # always clickable and a 4xx would surface nothing useful.
            return reply.no_content()

        var id = reply.param_int(m.params[0])
        if id >= 0:
            var text = String("")
            if m.handler_id == H_EDIT:
                # The form's fields, or None for any other body: a JSON
                # signal store posted here is refused, not read as a field
                # named after itself.
                var maybe = form(req)
                if not maybe:
                    return reply.problem(
                        400, "Invalid Rename",
                        "the request body must be application/x-www-form-urlencoded",
                        url_for(EDIT, String(id)),
                    )
                text = maybe.value().first("text")
                if text.byte_length() == 0:
                    return reply.no_content()
            # A stale tab racing a delete makes these no-ops; the broadcast
            # below still runs and corrects that tab's view. 204 either way.
            self.db.begin_immediate()
            try:
                if m.handler_id == H_EDIT:
                    var ren = self.db.prepare("UPDATE todos SET text = ? WHERE id = ?")
                    ren.bind_text(1, text)
                    ren.bind_int(2, id)
                    _ = ren.step()
                elif m.handler_id == H_TOGGLE:
                    var upd = self.db.prepare(
                        "UPDATE todos SET done = 1 - done WHERE id = ?"
                    )
                    upd.bind_int(1, id)
                    _ = upd.step()
                else:
                    var rm = self.db.prepare("DELETE FROM todos WHERE id = ?")
                    rm.bind_int(1, id)
                    _ = rm.step()
                self._commit()
            except e:
                self._abandon()
                raise e^
        return reply.no_content()

    # --- The three SSE hooks, wired straight through to the stream ----------

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.stream.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.stream.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.stream.closed(slot)

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        # A broadcast from another worker: queue it for this worker's
        # subscribers (and journal it, so replay works on every worker).
        self.stream.deliver_peer(url, event_id, frame)


def main() raises:
    var config = AppConfig()
    print(
        "Datastar todos on " + config.base_url
        + " — open it in two tabs (db: " + getenv("M0_DB", "todos.db") + ")"
    )
    serve[TodoHandler](config)
