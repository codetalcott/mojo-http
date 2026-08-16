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
are `Router` routes with `:id` captures —

    GET  /              the page, list already rendered
    GET  /events        opens the SSE stream (data-on-load)
    POST /add           reads the draft signal, inserts, broadcasts
    POST /toggle/:id    flips done, broadcasts
    POST /delete/:id    removes, broadcasts

One process only: SSE fan-out is per-process, so `M0_WORKERS>1` would split
tabs across workers that cannot see each other's broadcasts. (SQLite itself
would cope — WAL mode — but the streams would not.)

Because this app links libsqlite3, it is built and run, never `mojo run`:
the JIT resolves symbols only from libraries already in its process, which
happens to work on macOS and fails on Linux. `poe serve-todo` does the right
thing.

Run it:  uv run poe serve-todo
"""

from std.os import getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.header import Headers, Header, HeaderKey

from m0_core.json_parse import parse_json_field

from m0_http import AppConfig, Router

from m0_datastar.stream import DatastarStream
from m0_datastar.signals import read_signals

from m0_sqlite import Connection, open

from datastar_todo.page import render_page, render_todos


comptime STREAM_URL = "/events"

# How many broadcast frames survive for replay — both the DatastarStream
# journal and the SQLite `events` table are pruned to this depth. A client
# further behind than this reconnects past the gap: it resumes live and its
# next mutation (or refresh) re-renders the full list anyway.
comptime JOURNAL_ENTRIES = 64

comptime H_ADD = 0
comptime H_TOGGLE = 1
comptime H_DELETE = 2


struct TodoHandler(HTTPService):
    """One shared todo list, every connected tab in sync, rows in SQLite."""

    var router: Router
    var stream: DatastarStream
    # The store is the database; every render loads fresh rows. Statements
    # are prepared per use — a statement cache was measured within noise for
    # this repo (docs/SQLITE_PERFORMANCE.md) and is deliberately absent.
    var db: Connection

    def __init__(out self, var db: Connection) raises:
        self.router = Router()
        self.router.add("POST", "/add", H_ADD)
        self.router.add("POST", "/toggle/:id", H_TOGGLE)
        self.router.add("POST", "/delete/:id", H_DELETE)
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.stream = DatastarStream(1024, journal_entries=JOURNAL_ENTRIES)
        # AUTOINCREMENT keeps ids never-reused across deletes and restarts,
        # matching what the in-memory version promised. `ORDER BY id` below
        # is what preserves insertion order — the visible order of the list.
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
        var saved = db.prepare("SELECT id, url, frame FROM events ORDER BY id")
        while saved.step():
            self.stream.restore(
                saved.column_text(1), saved.column_int(0), saved.column_blob(2)
            )
        self.db = db^

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
            return OK('{"status":"ok"}', "application/json")

        if path == "/":
            var rows = self._load()
            return _html(render_page(rows[0], rows[1], rows[2]))

        if path == STREAM_URL:
            return self.stream.open(req, STREAM_URL)

        var m = self.router.match(req.method, path)
        if not m.matched:
            return _not_found()

        if m.handler_id == H_ADD:
            # The browser posts its signal store; the draft is all we want.
            var draft = parse_json_field(read_signals(req), "draft")
            if draft.byte_length() > 0:
                var ins = self.db.prepare(
                    "INSERT INTO todos (text) VALUES (?)"
                )
                ins.bind_text(1, draft)
                _ = ins.step()
                self._broadcast()
            # Empty drafts are ignored, not an error: the Add button is
            # always clickable and a 4xx would surface nothing useful.
            return _no_content()

        var id = _parse_id(m.params[0])
        if id >= 0:
            # A stale tab racing a delete makes these no-ops; the broadcast
            # below still runs and corrects that tab's view. 204 either way.
            if m.handler_id == H_TOGGLE:
                var upd = self.db.prepare(
                    "UPDATE todos SET done = 1 - done WHERE id = ?"
                )
                upd.bind_int(1, id)
                _ = upd.step()
            else:
                var rm = self.db.prepare("DELETE FROM todos WHERE id = ?")
                rm.bind_int(1, id)
                _ = rm.step()
            self._broadcast()
        return _no_content()

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    # --- The three SSE hooks, wired straight through to the stream ----------

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.stream.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.stream.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.stream.closed(slot)


def _html(body: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, "text/html; charset=utf-8")
        ),
        status_code=200,
        status_text="OK",
    )


def _no_content() -> HTTPResponse:
    # Mutations need no body: the update arrives over the stream.
    return HTTPResponse(
        body_bytes=String("").as_bytes(),
        status_code=204,
        status_text="No Content",
    )


def _not_found() -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String('{"error":"not found"}').as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=404,
        status_text="Not Found",
    )


def _parse_id(s: String) -> Int:
    if s.byte_length() == 0:
        return -1
    var result = 0
    var bytes = s.as_bytes()
    for i in range(s.byte_length()):
        var c = Int(bytes[i])
        if c < ord("0") or c > ord("9"):
            return -1
        result = result * 10 + (c - ord("0"))
    return result


def main() raises:
    var config = AppConfig()
    var db_path = getenv("M0_DB", "todos.db")
    print(
        "Datastar todos on " + config.base_url
        + " — open it in two tabs (db: " + db_path + ")"
    )
    var server = Server()
    var handler = TodoHandler(open(db_path))
    # SSE requires `listen_and_serve_nonblocking`, not `listen_and_serve`:
    # only the non-blocking event loop assigns `req.slot_id` and drains the
    # outbox; the plain accept loop would answer every stream open with 409.
    server.listen_and_serve_nonblocking(config.address(), handler)
