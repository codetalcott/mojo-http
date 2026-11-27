"""Table notes — a resource over a SQLite table, cached by the change clock.

`apps/fragment_notes` keeps its notes in a list in one process. These are
rows of a table, in a file any number of loops, workers and other programs
may open, and the app is what that takes:

- **the resource is its routes, named once.** `v.resource(NOTES, new=...,
  create=..., show=..., edit=..., update=..., delete=...)` is the table
  below. Create and edit are PLAIN forms answered with a 303, which is why
  `update` is reached by `POST /notes/:id/edit` as well as by PUT: a form
  cannot PUT. The DELETE is the one swap, a button in the list.
- **two connections per thread, and the reader never writes.** `writer`
  is `open()`, `reader` is `open_readonly()` on the same file. Every view
  renders through the reader, so what it renders and the clock it asks are
  one connection's.
- **the list is looked at again when the clock moves, and rendered again
  only when its table's pages were written.**
  - `reader.data_version()` is a number that differs once another
    connection has committed, this thread's own writer included. The view
    asks it (about a microsecond).
  - When the clock has moved, a `TableWitness` over `notes` (`m0_sqlite`,
    O32) reads the frames committed since its last look. If none wrote a
    page of `notes`, the kept rendering stands, with no SQL.
  - Otherwise, or when the witness can't tell, the page is read again and
    only the rows whose title changed are rendered: a row's `<li>` reads
    its id and its title and nothing else.
  - That view fills a cache, so it writes, and registers with `add_write`
    beside the resource rather than in its `list` slot.
- **the validator is a hash of what is sent.** `conditional` puts an
  `ETag` over the response's own body and answers 304 to a client that
  names it. A commit to another table moves the clock and writes no page
  of `notes`, so it costs no rendering and leaves the tag where it was.
- **a row has one name.** The id in a URL is the rowid written the one
  way a number is: `/notes/7` is the row and `/notes/07` is a 404. And a
  name has one row: the key is `AUTOINCREMENT`, so a deleted note's id is
  not given to the next.
- **the page is what is rendered.** A list is `LIST_PAGE` rows after a
  rowid (`?after=`), the same continuation under inserts and deletes
  between two reads; only the first page is kept.

- **what changed is asked of the database.** The table is watched
  (`m0_sqlite`'s stamps), so each row written, here or by any program,
  carries the number of its last change. `GET /notes/changes?since=N`
  answers the rows stamped above N in one statement: the ones that live
  with their titles, `born` when the client cannot have them, and the
  ones that are gone. A client keeps `head` and asks again from it; no
  loop keeps anything for it, so either loop answers. Below the floor
  (tombstones pruned, or a write no stamp saw: below), the answer is
  `reset`: read the list again.
  The list's cache is never kept on a stamp, which a write can get past:
  a REPLACE without the pragma, a rebuilt table, a connection with
  triggers turned off, blob I/O. The clock says when to look, and the
  witness, reading the pages SQLite wrote, says whether `notes` can have
  changed (D71).
- **the list is live, from either loop, and the server keeps nothing for
  the page.** `GET /notes/events` is a `Feed` (`m0_http.feed`): each
  subscriber stands at a stamp, the loop's tick asks the clock, and when
  it has moved each subscriber is sent the rows stamped above where IT
  stands -- an `<li>` per row, `hx-swap-oob` saying replace or delete,
  the new ones inside a `<ul id="notes-list" hx-swap-oob="beforeend">`,
  each after a delete of its id, so an id that came back is one row
  -- as one event carrying the new stamp as its id. A reconnect
  with `Last-Event-ID` is the same question; below the floor, or above
  the head, the event is `resync` and carries the first page whole. The
  page's script is one line: an `EventSource` from the stamp the fragment
  was rendered at, and `htmx.swap`. A fragment rendered again opens the
  feed again from its own stamp, so no row is appended twice.
- **a write no stamp saw starts every client over.** A client holding a
  row that such a write changed would keep its old title for good. The
  table's own triggers keep a copy of each row's title (`notes_seen`) in
  the transaction that writes the row, so such a write leaves the two
  different, in the file. Every answer that serves the first page or
  what changed, and the feed's tick, compares the first `CHECK_WINDOW`
  rows (100) with their copies, in the snapshot the answer is read in;
  any thread finds what any other served. A difference raises the floor
  (`m0_sqlite.raise_floor_within`, D72), so every client starts over:
  `reset` from `/notes/changes`, `resync` from the feed; the copies are
  set to what the check saw in the same transaction. A restore puts rows
  and copies back together, so it is found otherwise: a head below the
  highest this thread has read, or a moved schema version, which the
  backup API moves and no stamped write moves back (a migration moves it
  too, and starts every client over as well). Each thread's state also
  raises the floor once as it starts, for a restore made while no server
  ran. A raise takes the write lock and waits for another writer up to
  the busy timeout, on whichever thread found the difference: with no
  pool threads, the loop waits with it. The check covers the window and
  nothing else: a client also holds every row born since it rendered, and
  a write no stamp saw to one of those beyond the window reaches it only
  at the next reset, or when the row comes into the window.

Nothing is shared between threads but the file. Each loop under
`M0_THREADS` and each pool thread builds its own `Notes`, with its own
two connections and its own cache, and every one of them serves what the
others wrote: no lock held across a render, no bus, no `max_workers`.
Their tags agree because they hash the same bytes. The gate runs it at
two loops on threads; forked workers would serve the same way, with the
caution every m0-sqlite application has on macOS, where a connection
opened after a fork wants `OS_ACTIVITY_MODE=disable`.

No session and so no CSRF token: `apps/fragment_notes` is the login, and
`m0 new --template auth` is the two together.

    GET    /notes            the list, a page of it; ETag, 304
    GET    /notes/new        the form that creates
    POST   /notes            `title` and `body`; 303 to the note, or 422
                             with the form and what was wrong
    GET    /notes/:id        one note; ETag, 304
    GET    /notes/:id/edit   the form that updates
    PUT    /notes/:id        the same fields; 303 to the note
    POST   /notes/:id/edit   the same view, for the form
    DELETE /notes/:id        removes it; answers the list
    GET    /notes/changes    `?since=N`: the rows stamped above N, as JSON
    GET    /notes/events     SSE: the same rows as `<li>`s, as they change
    GET    /stats            this thread's cache, witness, check and stamp:
                             {"worker","fills","clock","head","watched",
                              "subscribers","feed_sent","feed_refused",
                              "looks","unchanged","changed","unknown",
                              "rows_rendered","checks","mismatches",
                              "restores","raises"}
    GET    /                 303 to /notes
    GET    /health           {"status":"ok"}

The database is `M0_DB`, else `table_notes.db` in the working directory.

Run it:  uv run poe serve-table-notes
"""

from std.collections import Dict
from std.os import getenv

from m0_server import HTTPRequest, HTTPResponse
from m0_host.flags import host_config
from m0_host.host import HostContext, ViewState, ViewsApp, serve

from m0_http import reply
from m0_http import (
    Cached,
    Feed,
    Fragment,
    Html,
    Htmx,
    PageShell,
    Query,
    RESOURCE_EDIT,
    RESOURCE_ITEM,
    RESOURCE_NEW,
    Views,
    attr,
    conditional,
    el,
    flag,
    form,
    page_or_fragment,
    text,
    url_for,
    void,
)
from m0_http.sse import format_sse_event
from m0_core.json_escape import escape_json_string
from m0_sqlite import (
    Connection,
    Statement,
    TableWitness,
    UNCHANGED,
    install_stamps,
    open,
    raise_floor,
    raise_floor_within,
    open_readonly,
    stamp_floor,
    stamp_head,
    watch,
    watched,
)

comptime HTMX_CDN = "https://cdn.jsdelivr.net/npm/htmx.org@4.0.0/dist/htmx.min.js"

comptime _STYLE = """<style>
body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}
form.note{display:grid;gap:.5rem}
input,textarea{font:inherit;padding:.4rem}
ul{list-style:none;padding:0}li{display:flex;gap:.5rem;align-items:center;padding:.3rem 0}
li button{margin-left:auto}
[role=alert]{color:#b00020}
</style>"""

# The collection's pattern, and the three `resource` registers under it.
comptime NOTES = "/notes"
comptime NOTES_NEW = NOTES + RESOURCE_NEW
comptime NOTE = NOTES + RESOURCE_ITEM
comptime NOTE_EDIT = NOTES + RESOURCE_EDIT
comptime NOTES_CHANGES = NOTES + "/changes"
comptime NOTES_EVENTS = NOTES + "/events"
"""Both registered before the resource: `/notes/:id` matches them too."""
comptime LIST_ID = "notes-list"

comptime NOTES_ID = "notes"
comptime Frag = Fragment[Htmx]

comptime LIST_PAGE = 50
"""Rows a list renders. The cache holds one page, so what a change costs
is a page and not the table."""

comptime CHECK_WINDOW = 2 * LIST_PAGE
"""Rows the check compares with their copies: the page and as many again.
Read as two ordered scans, rows and copies, merged as they are read, per
answer after a write."""

comptime WINDOW_SQL = "SELECT id, title FROM notes ORDER BY id"
"""The check's first scan: the rows, in id order."""

comptime SEEN_SQL = "SELECT id, title FROM notes_seen ORDER BY id"
"""Its second: the copies, in id order, merged with the rows as both are
read. No row is probed for its copy, nor a copy for its row."""

comptime DB_ENV = "M0_DB"
comptime DB_DEFAULT = "table_notes.db"


# --- state --------------------------------------------------------------------


comptime SEEN = """
CREATE TABLE IF NOT EXISTS notes_seen(id INTEGER PRIMARY KEY, title TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS notes_seen_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_seen (id, title) SELECT new.id, new.title
        WHERE NOT EXISTS (SELECT 1 FROM notes_seen WHERE id = new.id);
END;
CREATE TRIGGER IF NOT EXISTS notes_seen_au AFTER UPDATE ON notes BEGIN
    UPDATE notes_seen SET title = new.title WHERE id = new.id AND old.id IS new.id;
    DELETE FROM notes_seen WHERE id = old.id AND old.id IS NOT new.id;
    INSERT INTO notes_seen (id, title) SELECT new.id, new.title
        WHERE old.id IS NOT new.id
        AND NOT EXISTS (SELECT 1 FROM notes_seen WHERE id = new.id);
END;
CREATE TRIGGER IF NOT EXISTS notes_seen_ad AFTER DELETE ON notes BEGIN
    DELETE FROM notes_seen WHERE id = old.id;
END;
"""
"""The copy of what the list renders, kept by the table's own triggers in
the transaction that writes each row. A write no trigger sees -- a
connection with triggers turned off, blob I/O -- leaves `notes` and
`notes_seen` different in the file itself, where any thread or program
can find it.

Each trigger writes only the copy its own write accounts for, so a
difference already there stays one: an insert never overwrites a copy
(a row a bypass deleted, then put back under its id, still differs), and
an update of the same key never creates one (a row a bypass inserted,
then edited, is still missing its copy). Written as `stamps.mojo` writes
its own: no upsert and no `OR REPLACE`, whose conflict clause the
statement that fires the trigger would replace."""


@fieldwise_init
struct Seen(Copyable, Movable):
    """A row of the window whose copy differs: what the check read of the
    row (`there`, `title`) and of its copy (`copied`, `kept`)."""

    var id: Int
    var there: Bool
    var title: String
    var copied: Bool
    var kept: String


struct Notes(ViewState):
    """One thread's two connections and its rendering of the first page."""

    var writer: Connection
    var reader: Connection
    """Read-only, and the one every view renders through: its
    `data_version` moves for the writer's commits as for anyone's."""
    var rows: Cached
    var rows_head: Int
    """The stamp the kept page was rendered at: where its reader stands."""
    var witness: TableWitness
    """Whether a page of `notes` or `notes_seen` was written since the kept
    page's look (O32)."""
    var items: Dict[Int, Item]
    """The kept page's rows, each rendering beside the title it came from."""
    var rows_rendered: Int
    """How many `<li>`s the first page has rendered: what `/stats` reads to say
    a change cost one row, not the page."""
    var feed: Feed
    var clock: Int
    """The clock the feed last fanned out at."""
    var worker: Int
    var highest: Int
    """The highest head this state has read. A head below it is a counter
    a restore took back."""
    var schema: Int
    """`PRAGMA schema_version` at the last check, -1 before the first. A
    restore through the backup API moves it, and stamped writes after it
    cannot move it back, as they can carry the head past `highest`; a
    migration moves it too, and one that rebuilds a table is a write no
    stamp saw."""
    var checks: Int
    var mismatches: Int
    var restores: Int
    var raises: Int
    var _now: Int
    var _looked: Bool
    var _answer: Int
    var _q_head: Statement
    var _q_schema: Statement
    var _q_window: Statement
    var _q_seen: Statement
    """Kept between answers on `reader`, and reset before and after each
    use, so none holds a read past its answer."""

    def __init__(out self, path: String, worker: Int, capacity: Int) raises:
        self.writer = open(path)
        # IMMEDIATE: `CREATE TABLE IF NOT EXISTS` reads first and upgrades
        # to a write, which SQLite refuses at once, not through the busy
        # handler, when two loops open one fresh file together.
        self.writer.begin_immediate()
        self.writer.execute(
            "CREATE TABLE IF NOT EXISTS notes ("
            "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "  title TEXT NOT NULL,"
            "  body TEXT NOT NULL DEFAULT '')"
        )
        install_stamps(self.writer)
        watch(self.writer, "notes")
        var made = self.writer.prepare(
            "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = 'notes_seen'"
        )
        _ = made.step()
        var fill = made.column_int(0) == 0
        made.finalize()
        self.writer.execute(SEEN)
        if fill:
            # Made now, so filled now, in the transaction that made it.
            self.writer.execute("INSERT INTO notes_seen (id, title) SELECT id, title FROM notes")
        self.writer.commit()
        # A REPLACE that displaces a row deletes it with no delete trigger
        # unless the writing connection says this. The app has no REPLACE;
        # the line is here for the one somebody adds.
        self.writer.execute("PRAGMA recursive_triggers = ON")
        # AUTOINCREMENT, so a deleted note's id is never handed to another:
        # without it SQLite reuses the highest rowid once its row is gone,
        # and a URL someone kept would name a different note.
        self.reader = open_readonly(path)
        self._q_head = self.reader.prepare("SELECT seq FROM m0_stamp WHERE id = 0")
        self._q_schema = self.reader.prepare("PRAGMA schema_version")
        self._q_window = self.reader.prepare(WINDOW_SQL)
        self._q_seen = self.reader.prepare(SEEN_SQL)
        self.rows = Cached()
        self.rows_head = 0
        self.witness = TableWitness(path, ["notes", "notes_seen"])
        self.items = Dict[Int, Item]()
        self.rows_rendered = 0
        self.feed = Feed(capacity)
        self.clock = 0
        self.worker = worker
        self.highest = 0
        self.schema = -1
        self.checks = 0
        self.mismatches = 0
        self.restores = 0
        self.raises = 0
        self._now = 0
        self._looked = False
        self._answer = UNCHANGED
        # A restore made while no server ran puts the rows, their copies and
        # the counter back together, so nothing differs; a client from
        # before may still hold what it replaced: every client starts over.
        self.raise_floor(String("startup"))

    @staticmethod
    def make(ctx: HostContext) raises -> Self:
        return Notes(getenv(DB_ENV, DB_DEFAULT), ctx.worker, ctx.capacity)

    def refresh(mut self) raises:
        """The feed's fan-out: when the clock has moved, or a subscriber is
        known to stand behind, bring each from where it stands to the head.
        Most stand together, so one delta serves them all. Checked first,
        in the snapshot the deltas are read in."""
        var now = self.reader.data_version()
        if now == self.clock and not self.feed.lagging():
            return
        self.look()
        self.reader.begin()
        try:
            self.check_in_snapshot()
            var head = stamp_head(self.reader)
            var have = -1
            var frames = String()
            var to = 0
            for slot in self.feed.behind(head):
                var at = self.feed.at(slot)
                if at != have:
                    have = at
                    to = at
                    frames = delta_frames(self.reader, at, to)
                if to == at:
                    self.feed.skip(slot, head)
                else:
                    _ = self.feed.send(slot, to, frames)
            self.reader.commit()
        except e:
            self.abandon()
            raise e^
        self.settle()
        self.clock = now

    def tick(mut self, now_ms: Int):
        try:
            self.refresh()
        except e:
            print("table_notes: the feed's tick failed:", e)

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.feed.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.feed.is_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.feed.closed(slot)

    @staticmethod
    def urls() raises -> Views[Self]:
        return note_urls()

    def first_page(mut self) raises -> String:
        """The first page of the list. When the clock has moved since it was
        kept, the witness says whether `notes` can have changed. If not, the
        kept page stands. If so, or when it can't tell, the page is checked
        and read again, and only its changed rows are rendered.

        The clock is asked BEFORE the look, and the look BEFORE the read
        transaction. A commit between them then costs one more rendering, and
        never a stale page: the read holds at least what the look read, and
        `settle` covers no more than that.

        The kept page also carries the stamp head it was rendered at, in its
        script. A write that moves it without writing `notes` (a floor
        raised by another thread or program) is found by the head the
        answer's own snapshot reads, in `check_in_snapshot`, which renders
        the page again under it."""
        if self.rows.current(self.reader.data_version()):
            return self.rows.body
        self.look()
        self.reader.begin()
        try:
            self.check_in_snapshot()
            self.reader.commit()
        except e:
            self.abandon()
            raise e^
        self.settle()
        return self.rows.body

    def answer_changes(mut self, since: Int) raises -> String:
        """`GET /notes/changes`' answer for a client at `since`, read in the
        snapshot its check was made in."""
        self.look()
        self.reader.begin()
        var body: String
        try:
            self.check_in_snapshot()
            body = _changes(self.reader, since)
            self.reader.commit()
        except e:
            self.abandon()
            raise e^
        self.settle()
        return body^

    # --- the check -------------------------------------------------------
    #
    # A stamp says what a trigger saw, and a write can get past a trigger.
    # The table's own triggers also keep a copy of what the list renders
    # (`notes_seen`), and a write that gets past them leaves the two
    # different, in the file. So the first `CHECK_WINDOW` rows are compared
    # with their copies in the snapshot each answer is read in, by whichever
    # thread answers; no thread's memory is involved. A difference raises
    # the floor over every client, who starts over, and the copies are then
    # set to what the check saw. The witness says when the check can be
    # skipped.

    def look(mut self) raises:
        """Before the answer's read transaction: ask the clock, and when it
        has moved, the witness (O32's order: the look before the read)."""
        self._now = self.reader.data_version()
        self._looked = not self.rows.current(self._now)
        self._answer = UNCHANGED
        if self._looked:
            self._answer = self.witness.look()

    def check_in_snapshot(mut self) raises:
        """Inside the answer's read transaction: keep the page if no page of
        `notes` or of its copy was written and the head is the kept page's,
        else check and render it in this snapshot. The head is read here, so
        a raise by another thread, which writes neither table, renders the
        page again under the new head."""
        var head = self._head()
        if (
            self.rows.filled
            and head == self.rows_head
            and (not self._looked or self._answer == UNCHANGED)
        ):
            if self._looked:
                self.rows.clock = self._now
            return
        self._check(head)

    def settle(mut self) raises:
        """After the answer's transaction committed."""
        if self._looked:
            self._looked = False
            self.witness.settle()

    def abandon(mut self):
        """After the answer failed: no settle, so the next look sees the
        same frames again."""
        self._looked = False
        try:
            self._q_head.reset()
            self._q_schema.reset()
            self._q_window.reset()
            self._q_seen.reset()
        except:
            pass
        try:
            self.reader.rollback()
        except:
            pass

    def _head(mut self) raises -> Int:
        """`stamp_head`, on the kept statement."""
        self._q_head.reset()
        _ = self._q_head.step()
        var head = self._q_head.column_int(0)
        self._q_head.reset()
        return head

    def _check(mut self, head: Int) raises:
        self.checks += 1
        var why = String()
        self._q_schema.reset()
        _ = self._q_schema.step()
        var schema = self._q_schema.column_int(0)
        self._q_schema.reset()
        var restored = head < self.highest or (self.schema >= 0 and schema != self.schema)
        if head < self.highest:
            why = String("the counter went back from ", self.highest, " to ", head, ": a restore")
        elif restored:
            why = String(
                "the schema version moved from ", self.schema, " to ", schema,
                ": a restore, or a migration",
            )
        var differ = List[Seen]()
        var gone = List[Seen]()
        var ids = List[Int]()
        var titles = List[String]()
        # A copy below the next row has no row and is gone; a row with no
        # copy at its id has none. The loop stops at the window's last row
        # and its copy, so a copy above that row is never read, and reads
        # every copy when the table is shorter than the window. The page is
        # rendered from the same rows.
        ref q = self._q_window
        ref s = self._q_seen
        q.reset()
        s.reset()
        var shown = 0
        var more_s = s.step()
        while shown < CHECK_WINDOW and q.step():
            var id = q.column_int(0)
            while more_s and s.column_int(0) < id:
                gone.append(Seen(s.column_int(0), False, String(), True, s.column_text(1)))
                more_s = s.step()
            shown += 1
            var title = q.column_text(1)
            if id > 0 and len(ids) <= LIST_PAGE:
                ids.append(id)
                titles.append(title.copy())
            if more_s and s.column_int(0) == id:
                var copy = s.column_text(1)
                more_s = s.step()
                if copy != title:
                    differ.append(Seen(id, True, title^, True, copy^))
            else:
                differ.append(Seen(id, True, title^, False, String()))
        if shown < CHECK_WINDOW:
            while more_s:
                gone.append(Seen(s.column_int(0), False, String(), True, s.column_text(1)))
                more_s = s.step()
        q.reset()
        s.reset()
        for ref d in gone:
            differ.append(d.copy())
        if len(differ) > 0 and why.byte_length() == 0:
            ref d = differ[0]
            if not d.there:
                why = String("mismatch: row ", d.id, " is gone, and its copy is not")
            elif not d.copied:
                why = String("mismatch: row ", d.id, " is there, and has no copy")
            else:
                why = String("mismatch: row ", d.id, "'s title is not its copy's")
        if why.byte_length() > 0:
            if restored:
                self.restores += 1
            else:
                self.mismatches += 1
            # The floor and the copies in one transaction: no other thread
            # can check between them, and a failure leaves the difference
            # in the file for the next check to find.
            self.writer.begin_immediate()
            try:
                var raised = raise_floor_within(self.writer)
                self._set_copies(differ)
                self.writer.commit()
                self._raised(raised, why)
            except e:
                if self.writer.in_transaction():
                    try:
                        self.writer.rollback()
                    except:
                        pass
                raise e^
        self.highest = max(self.highest, head)
        self.schema = schema
        # The stamp and the rows in one snapshot: a row born after the stamp
        # would be in the page AND appended by the feed.
        self.rows_head = head
        var body: String
        if shown == CHECK_WINDOW and len(ids) <= LIST_PAGE:
            # The window holds fewer than a page and one of rows the list
            # shows (ids above 0): the page needs rows past it.
            body = render_list_reusing(self.reader, 0, head, self.items, self.rows_rendered)
        else:
            var more = len(ids) > LIST_PAGE
            if more:
                _ = ids.pop()
                _ = titles.pop()
            body = render_rows_reusing(ids, titles, more, 0, head, self.items, self.rows_rendered)
        _ = self.rows.fill(self._now, body^)

    def _set_copies(mut self, differ: List[Seen]) raises:
        """Inside the writer's open transaction: set each differing copy to
        what the check saw, where it is still what the check read. A
        stamped write since, whose trigger made the copy agree, is left
        alone; a write no trigger saw since is not taken in, since the copy
        gets the title the check saw, not the table's now. Compared as
        bytes: a title another program stored as a BLOB never equals the
        TEXT bound here, and a copy that never matched would raise the
        floor at every check."""
        for ref d in differ:
            if not d.there:
                var x = self.writer.prepare(
                    "DELETE FROM notes_seen WHERE id = ?1"
                    " AND CAST(title AS BLOB) = CAST(?2 AS BLOB)"
                )
                x.bind_int(1, d.id)
                x.bind_text(2, d.kept)
                _ = x.step()
                x.finalize()
            elif not d.copied:
                var x = self.writer.prepare(
                    "INSERT INTO notes_seen (id, title) SELECT ?1, ?2"
                    " WHERE NOT EXISTS (SELECT 1 FROM notes_seen WHERE id = ?1)"
                )
                x.bind_int(1, d.id)
                x.bind_text(2, d.title)
                _ = x.step()
                x.finalize()
            else:
                var x = self.writer.prepare(
                    "UPDATE notes_seen SET title = ?1 WHERE id = ?2"
                    " AND CAST(title AS BLOB) = CAST(?3 AS BLOB)"
                )
                x.bind_text(1, d.title)
                x.bind_int(2, d.id)
                x.bind_text(3, d.kept)
                _ = x.step()
                x.finalize()

    def raise_floor(mut self, why: String) raises:
        """Every client starts over (`m0_sqlite.raise_floor`, O33): the feed
        sends each subscriber `resync`, and `/notes/changes` answers
        `reset`. In a transaction of its own."""
        self._raised(raise_floor(self.writer), why)

    def _raised(mut self, head: Int, why: String):
        """Counted, and logged with the reason, on stdout."""
        self.raises += 1
        print(
            String("table_notes: worker ", self.worker, " raised the floor to ", head, ": ", why),
            flush=True,
        )


# --- templates -----------------------------------------------------------------


struct Site(PageShell):
    var title: String

    def __init__(out self, var title: String):
        self.title = title^

    def wrap(self, fragment: String) raises -> String:
        var h = Html(1024)
        h.raw('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n')
        h.raw('<meta name="viewport" content="width=device-width,initial-scale=1">\n')
        h.open("title")
        h.text(self.title)
        h.close("title")
        h.raw("\n")
        h.open("script")
        h.attr("src", HTMX_CDN)
        h.close("script")
        h.raw("\n")
        h.raw(_STYLE)
        h.raw("\n</head>\n<body>\n<main>\n")
        h.raw(fragment)
        h.raw("\n</main>\n</body>\n</html>\n")
        return h^.finish()


def render_item(f: Frag, id: Int, title: String, oob: String) raises -> String:
    """One row of the list. `oob` is empty in the list itself and in the
    rows a feed event appends (those travel inside a `<ul id="notes-list"
    hx-swap-oob="beforeend">`, since htmx 4 inserts an out-of-band
    element's CHILDREN for a positional swap); a changed row carries
    `true`, to replace its own by id."""
    var url = url_for(NOTE, String(id))
    var attrs = attr("id", "n" + String(id))
    if oob.byte_length() > 0:
        attrs += attr("hx-swap-oob", oob)
    return el("li", attrs,
        f.el("a", "get", url, attr("href", url), text(title), push=True),
        f.el("button", "delete", url, attr("aria-label", "delete"), "&times;"),
    )


comptime _FEED_SCRIPT = (
    "if(window.notesFeed)window.notesFeed.close();window.notesFeed=new EventSource('"
    + NOTES_EVENTS + "?since="
)
"""Opens the feed from the stamp THIS rendering was made at, closing the
one before: a fragment rendered again (the DELETE's answer, "all notes")
holds rows the old feed had not yet sent, and a feed left at its old
place would append them twice. Each event goes to htmx: an oob event
swaps nothing itself and lets its rows find their places; a resync
replaces the whole fragment. `htmx.swap` is htmx 4's public swap."""
comptime _FEED_SCRIPT_TAIL = (
    "');notesFeed.addEventListener('notes',e=>htmx.swap({text:e.data,target:document.body,"
    "swap:'none'}));notesFeed.addEventListener('resync',e=>htmx.swap({text:e.data,"
    "target:document.getElementById('" + NOTES_ID + "'),swap:'outerHTML'}))"
)


@fieldwise_init
struct Item(Copyable, Movable):
    """One row's rendering, and the title it was rendered from."""

    var title: String
    var li: String


def render_list(db: Connection, after: Int, head: Int = -1) raises -> String:
    """The `notes` fragment: `LIST_PAGE` rows after rowid `after`, and a
    link to the rows after those when there are any. With `head`, the
    first page carries the script that keeps it live from that stamp."""
    var none = Dict[Int, Item]()
    var rendered = 0
    return render_list_reusing(db, after, head, none, rendered)


def render_list_reusing(
    db: Connection, after: Int, head: Int, mut items: Dict[Int, Item], mut rendered: Int
) raises -> String:
    """`render_list`, taking each row's `<li>` from `items` when the row's title
    is the one it was rendered from, and leaving `items` holding this page's
    rows. A row's `<li>` reads its id and title and nothing else, so those
    two are its key. The row itself says whether its rendering is current;
    no stamp does."""
    var q = db.prepare("SELECT id, title FROM notes WHERE id > ?1 ORDER BY id LIMIT ?2")
    q.bind_int(1, after)
    q.bind_int(2, LIST_PAGE + 1)
    var ids = List[Int]()
    var titles = List[String]()
    var more = False
    while q.step():
        if len(ids) == LIST_PAGE:
            more = True
            break
        ids.append(q.column_int(0))
        titles.append(q.column_text(1))
    q.finalize()
    return render_rows_reusing(ids, titles, more, after, head, items, rendered)


def render_rows_reusing(
    ids: List[Int],
    titles: List[String],
    more: Bool,
    after: Int,
    head: Int,
    mut items: Dict[Int, Item],
    mut rendered: Int,
) raises -> String:
    """`render_list_reusing` from rows already read: at most `LIST_PAGE` of
    them, in id order, after rowid `after`, and whether more follow."""
    var f = Frag(NOTES_ID)
    f.raw(el("p", "", el("a", attr("href", NOTES_NEW), "New note")))
    var html = String()
    var last = after
    var kept = Dict[Int, Item]()
    for i in range(len(ids)):
        last = ids[i]
        var current = False
        if last in items:
            current = items[last].title == titles[i]
        var li: String
        if current:
            li = items[last].li
        else:
            li = render_item(f, last, titles[i], String(""))
            rendered += 1
        html += li
        kept[last] = Item(titles[i].copy(), li^)
    items = kept^
    f.raw(el("ul", attr("id", LIST_ID), html))
    if len(ids) == 0:
        f.raw(el("p", attr("id", "none-yet"), text("none yet")))
    if more:
        var next = Query()
        next.add("after", String(last))
        var url = next.on(url_for(NOTES))
        f.raw(el("p", "", f.el("a", "get", url, attr("href", url), "More", push=True)))
    if head >= 0:
        f.raw(el("script", "", _FEED_SCRIPT + String(head) + _FEED_SCRIPT_TAIL))
    return f^.finish()


def delta_frames(db: Connection, since: Int, mut head: Int) raises -> String:
    """The feed's event for a subscriber at `since`: the rows stamped above
    it as `<li>`s with their `hx-swap-oob`, the new stamp as the id; or
    `resync` with the first page whole, below the floor or above the head.
    Read in the caller's transaction, the one its check was made in, so one
    snapshot. `head` is left where the subscriber will stand, `since` when
    there is nothing for it."""
    var top = stamp_head(db)
    var low = stamp_floor(db)
    var out = String()
    if since < low or since > top:
        head = top
        out = format_sse_event(top, "resync", render_list(db, 0, top))
    else:
        var q = db.prepare(
            "SELECT c.row, c.seq, c.born, c.gone, n.title FROM m0_changes c"
            " LEFT JOIN notes n ON n.id = c.row"
            " WHERE c.tbl = 'notes' AND c.seq > ?1 ORDER BY c.seq"
        )
        q.bind_int(1, since)
        var f = Frag(NOTES_ID)
        var rows = String()
        var born = String()
        var last = since
        while q.step():
            last = q.column_int(1)
            var id = q.column_int(0)
            if q.column_int(3) == 1 or q.is_null(4):
                rows += el("li", attr("id", "n" + String(id)) + attr("hx-swap-oob", "delete"))
            elif q.column_int(2) > since:
                # Born above the subscriber's stamp, so it lacks the row --
                # unless the id came back (an insert under a deleted row's
                # id, a REPLACE): its old row may still be on the page. So
                # the old one goes first, and the append is the one row;
                # htmx skips a target that is not there.
                rows += el("li", attr("id", "n" + String(id)) + attr("hx-swap-oob", "delete"))
                born += render_item(f, id, q.column_text(4), String(""))
            else:
                rows += render_item(f, id, q.column_text(4), String("true"))
        _ = f^.finish()
        if born.byte_length() > 0:
            # The empty list's "none yet" goes when the first row comes;
            # htmx skips a target that is not there.
            rows += el("p", attr("id", "none-yet") + attr("hx-swap-oob", "delete"))
            rows += el("ul", attr("id", LIST_ID) + attr("hx-swap-oob", "beforeend"), born)
        head = last
        if last > since:
            out = format_sse_event(last, "notes", rows)
    return out


def events(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """GET /notes/events — the list, live. Answered on the loop, whose
    state holds the feed; the next tick sends what the client is missing
    (a refresh here would turn its raise into a 500 on a stream half
    opened)."""
    return st.feed.open(req, NOTES_ID)


def render_note(id: Int, title: String, body: String) raises -> String:
    var f = Frag(NOTES_ID)
    f.raw(el("article", "", el("h1", "", text(title)), el("p", "", text(body))))
    var edit = url_for(NOTE_EDIT, String(id))
    f.raw(el("p", "",
        el("a", attr("href", edit), "Edit"), " ",
        f.el("a", "get", NOTES, attr("href", NOTES), "all notes", push=True),
    ))
    return f^.finish()


def render_form(action: String, title: String, body: String, error: String) raises -> String:
    """The form that creates or updates: a plain `<form method="post">`
    to `action`, answered with a 303. Not a swap: saving is a navigation,
    and the address it lands on is the note's."""
    var f = Frag(NOTES_ID)
    if error.byte_length() > 0:
        f.raw(el("p", attr("role", "alert"), text(error)))
    f.raw(el("form", attr("class", "note") + attr("method", "post") + attr("action", action),
        void("input", attr("name", "title") + attr("value", title) + attr("placeholder", "title") + flag("required")),
        el("textarea", attr("name", "body") + attr("placeholder", "body"), text(body)),
        el("button", "", "Save"),
    ))
    f.raw(el("p", "", el("a", attr("href", NOTES), "all notes")))
    return f^.finish()


def render_missing() raises -> String:
    var f = Frag(NOTES_ID)
    f.raw(el("p", attr("role", "alert"), text("no note with this id")))
    f.raw(el("p", "", el("a", attr("href", NOTES), "all notes")))
    return f^.finish()


# --- views ---------------------------------------------------------------------


def rowid(param: String) -> Int:
    """The row a `:id` capture names, or -1. A row has ONE name: its
    rowid in decimal, no sign and no leading zero, so `07` names nothing
    and two URLs never answer one row. SQLite's rowids start at 1."""
    if param.byte_length() == 0 or Int(param.as_bytes()[0]) == ord("0"):
        return -1
    return reply.param_int(param)


def _missing(req: HTTPRequest) raises -> HTTPResponse:
    return page_or_fragment(req, render_missing(), Site("not found"), status=404)


def index(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """GET /notes — a page of the list. It fills the cache, so it writes."""
    var after = 0
    ref q = req.uri.queries
    if "after" in q:
        after = rowid(q["after"])
        if after < 0:
            return _missing(req)
    if after == 0:
        return conditional(req, page_or_fragment(req, st.first_page(), Site("notes")))
    return conditional(
        req, page_or_fragment(req, render_list(st.reader, after), Site("notes"))
    )


def new_form(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /notes/new — the form that creates."""
    return page_or_fragment(
        req, render_form(NOTES, String(""), String(""), String("")), Site("new note")
    )


def create(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """POST /notes — 303 to the note it made."""
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Note",
            "the request body must be application/x-www-form-urlencoded",
            NOTES,
        )
    var f = maybe.take()
    var title = f.first("title")
    var body = f.first("body")
    if title.byte_length() == 0:
        return page_or_fragment(
            req,
            render_form(NOTES, title, body, String("a title is required")),
            Site("new note"),
            status=422,
        )
    var ins = st.writer.prepare("INSERT INTO notes (title, body) VALUES (?1, ?2)")
    ins.bind_text(1, title)
    ins.bind_text(2, body)
    _ = ins.step()
    return reply.redirect(303, url_for(NOTE, String(st.writer.last_insert_rowid())))


def detail(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /notes/:id — one note."""
    var id = rowid(params[0])
    var q = st.reader.prepare("SELECT title, body FROM notes WHERE id = ?1")
    q.bind_int(1, id)
    if id < 0 or not q.step():
        return _missing(req)
    var title = q.column_text(0)
    return conditional(
        req, page_or_fragment(req, render_note(id, title, q.column_text(1)), Site(title))
    )


def edit_form(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /notes/:id/edit — the form that updates, posting to itself."""
    var id = rowid(params[0])
    var q = st.reader.prepare("SELECT title, body FROM notes WHERE id = ?1")
    q.bind_int(1, id)
    if id < 0 or not q.step():
        return _missing(req)
    return page_or_fragment(
        req,
        render_form(
            url_for(NOTE_EDIT, String(id)), q.column_text(0), q.column_text(1), String("")
        ),
        Site("edit note"),
    )


def update(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """PUT /notes/:id, and POST /notes/:id/edit — 303 to the note."""
    var id = rowid(params[0])
    # The row first: a form for a note that is not there is a 404, whatever
    # is wrong with the form.
    var there = st.reader.prepare("SELECT 1 FROM notes WHERE id = ?1")
    there.bind_int(1, id)
    if id < 0 or not there.step():
        return _missing(req)
    var maybe = form(req)
    if not maybe:
        return reply.problem(
            400, "Invalid Note",
            "the request body must be application/x-www-form-urlencoded",
            req.uri.path,
        )
    var f = maybe.take()
    var title = f.first("title")
    var body = f.first("body")
    if title.byte_length() == 0:
        return page_or_fragment(
            req,
            render_form(url_for(NOTE_EDIT, String(id)), title, body, String("a title is required")),
            Site("edit note"),
            status=422,
        )
    var up = st.writer.prepare("UPDATE notes SET title = ?1, body = ?2 WHERE id = ?3")
    up.bind_text(1, title)
    up.bind_text(2, body)
    up.bind_int(3, id)
    _ = up.step()
    if st.writer.changes() == 0:
        return _missing(req)
    return reply.redirect(303, url_for(NOTE, String(id)))


def delete(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """DELETE /notes/:id — the one swap: answers the list without it."""
    var id = rowid(params[0])
    if id < 0:
        return _missing(req)
    var del_ = st.writer.prepare("DELETE FROM notes WHERE id = ?1")
    del_.bind_int(1, id)
    _ = del_.step()
    if st.writer.changes() == 0:
        return _missing(req)
    return page_or_fragment(req, st.first_page(), Site("notes"))


def stamp(param: String) -> Int:
    """The stamp a `since` names, or -1: decimal digits, no sign, and no
    leading zero but for 0 itself."""
    if param == "0":
        return 0
    return rowid(param)


def json_text(s: String) -> String:
    """`s` as a JSON string. A title is what a form or another program
    stored, so it may hold bytes that are not UTF-8: each such byte
    becomes U+FFFD, since one undecodable row would make every delta
    that includes it unreadable, and a delta cannot skip a row."""
    var b = s.as_bytes()
    var n = len(b)
    var clean = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var c = Int(b[i])
        var want = 0
        if c < 0x80:
            want = 1
        elif c >= 0xC2 and c <= 0xDF:
            want = 2
        elif c >= 0xE0 and c <= 0xEF:
            want = 3
        elif c >= 0xF0 and c <= 0xF4:
            want = 4
        var ok = want > 0 and i + want <= n
        if ok:
            for k in range(1, want):
                var t = Int(b[i + k])
                if t < 0x80 or t > 0xBF:
                    ok = False
            # Overlong forms, surrogates and what lies past U+10FFFF.
            if want == 3 and ok:
                var t = Int(b[i + 1])
                ok = not (c == 0xE0 and t < 0xA0) and not (c == 0xED and t > 0x9F)
            if want == 4 and ok:
                var t = Int(b[i + 1])
                ok = not (c == 0xF0 and t < 0x90) and not (c == 0xF4 and t > 0x8F)
        if ok:
            for k in range(want):
                clean.append(b[i + k])
            i += want
        else:
            clean.append(0xEF)
            clean.append(0xBF)
            clean.append(0xBD)
            i += 1
    return escape_json_string(String(unsafe_from_utf8=Span(clean)))


def _changes(db: Connection, since: Int) raises -> String:
    """The answer for a client at `since`, read inside one transaction."""
    var head = stamp_head(db)
    if since < stamp_floor(db) or since > head:
        # Below the floor, deletions are no longer recorded, and a delta
        # could leave the client a note that is gone. Above the head, the
        # client's stamp is not this database's (a file restored or made
        # again): it would hear nothing until the counter passed it, then
        # miss what lay between.
        return String('{"since":', since, ',"head":', head, ',"reset":true,"rows":[]}')
    var q = db.prepare(
        "SELECT c.row, c.seq, c.born, c.gone, n.title FROM m0_changes c"
        " LEFT JOIN notes n ON n.id = c.row"
        " WHERE c.tbl = 'notes' AND c.seq > ?1 ORDER BY c.seq"
    )
    q.bind_int(1, since)
    var rows = String()
    while q.step():
        if rows.byte_length() > 0:
            rows += ","
        rows += String('{"id":', q.column_int(0), ',"seq":', q.column_int(1))
        if q.column_int(3) == 1 or q.is_null(4):
            rows += ',"gone":true}'
        else:
            rows += String(
                ',"born":', "true" if q.column_int(2) > since else "false",
                ',"title":', json_text(q.column_text(4)), "}",
            )
    q.finalize()
    return String('{"since":', since, ',"head":', head, ',"reset":false,"rows":[', rows, "]}")


def changes(
    req: HTTPRequest, params: List[String], mut st: Notes
) raises -> HTTPResponse:
    """GET /notes/changes?since=N — the rows stamped above N.

    The floor, the head and the rows are read in one transaction, so one
    snapshot: `head` is the last stamp given as of it, and a client that
    asks again from `head` misses nothing. The answer is whole however
    long: `born` says the row was created above N, which tells a client
    it lacks the row only when N was some answer's `head`.
    """
    var since = 0
    ref query = req.uri.queries
    if "since" in query:
        since = stamp(query["since"])
    if since < 0:
        return reply.problem(
            400, "Invalid Stamp", "since is a stamp: decimal digits", NOTES_CHANGES
        )
    return reply.json(200, "OK", st.answer_changes(since))


def stats(
    req: HTTPRequest, params: List[String], st: Notes
) raises -> HTTPResponse:
    """GET /stats — how often this thread's state rendered the list, what
    its witness answered and its check found, and where the stamps stand,
    for the gate."""
    return reply.json(
        200, "OK",
        String(
            '{"worker":', st.worker, ',"fills":', st.rows.fills,
            ',"clock":', st.reader.data_version(),
            ',"head":', stamp_head(st.reader),
            ',"watched":', "true" if watched(st.reader, "notes") else "false",
            ',"subscribers":', st.feed.subscribers(NOTES_ID),
            ',"feed_sent":', st.feed.sent, ',"feed_refused":', st.feed.refused,
            ',"looks":', st.witness.looks, ',"unchanged":', st.witness.unchanged,
            ',"changed":', st.witness.changed, ',"unknown":', st.witness.unknown,
            ',"rows_rendered":', st.rows_rendered,
            ',"checks":', st.checks, ',"mismatches":', st.mismatches,
            ',"restores":', st.restores, ',"raises":', st.raises, "}",
        ),
    )


def root(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.redirect(303, NOTES)


def health(req: HTTPRequest, params: List[String]) -> HTTPResponse:
    return reply.json(200, "OK", '{"status":"ok"}')


# --- the table -----------------------------------------------------------------


def note_urls() raises -> Views[Notes]:
    var v = Views[Notes]()
    v.add_loop("GET", "/health", health)
    v.add_loop("GET", "/", root)
    v.add_read("GET", "/stats", stats)
    # The list fills a cache as it answers, so it is a write and takes the
    # collection's GET itself; `resource` registers the rest.
    v.add_write("GET", NOTES, index)
    # Before the resource: the router answers with the first match. The
    # feed opens on the loop, whose state holds it (D32).
    v.add_write("GET", NOTES_CHANGES, changes)
    v.add_write("GET", NOTES_EVENTS, events, on_loop=True)
    v.resource(
        NOTES, new=new_form, create=create, show=detail, edit=edit_form,
        update=update, delete=delete,
    )
    return v^


def main() raises:
    var config = host_config()
    if config.app_tick_ms == 0:
        config.app_tick_ms = 50
    print(
        String("Table notes on ", config.base_url, " over ", getenv(DB_ENV, DB_DEFAULT)),
        flush=True,
    )
    serve[ViewsApp[Notes]](config)
