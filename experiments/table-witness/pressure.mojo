"""Phase 3 of plan-d63-witness-2026-11-25.md: the witness under checkpoint pressure.

    pressure <db> <control-dir> <seconds> <mode> [B]

The reader half; `pressure_writer.py` builds the database and writes. Modes:
0 correct; 1 "the table changed" taken for "unchanged"; 2 the position read
after the read transaction (covers frames the rendering may not hold);
3 salts ignored (a WAL reset read as the same generation).

Phase 2's description follows.

Phase 2 of plan-d63-witness-2026-11-25.md: what a cache rule better than D63 costs.

A copy of zero-transcode's notes-rowcache/bench_notes.mojo (follow-up 1) with
the arms W, Rk, Ck, D2k (stamps trusted only while `watched()` holds as of the
schema version) and D3k (the WAL page witness: keep the page when no frame since
the last check wrote a page of `notes`, page 1, or a new WAL).

    bench_notes3 <db-path> <hot|uniform> <seed> [sabotage-d3]

Its predecessor's description follows.

Attempt 3 (plan-zero-transcode-2026-11-24.md): stamp-driven row caching in a
probe copy of mojo-http's apps/table_notes (at 31fb5841).

    bench_notes <db-path> <hot|uniform> <seed> [sabotage-r|sabotage-c]

In process, no HTTP. `render_item`, `_FEED_SCRIPT`, `_FEED_SCRIPT_TAIL` and
`render_list` below are copied verbatim from apps/table_notes/server.mojo,
with the constants they name. Arms, each on its own read-only connection:
  W  the app's `first_page`: on a moved clock, render the whole first page.
  R  rows cached: on a moved clock, re-render only the cached rows stamped
     above the cached head, render the ids the cache lacks, assemble.
"""

from std.collections import Dict, List
from std.ffi import c_int, external_call
from std.io.file import FileHandle
from std.sys import argv
from std.time import perf_counter_ns, sleep

from m0_http import (
    Cached,
    Fragment,
    Htmx,
    Query,
    RESOURCE_EDIT,
    RESOURCE_ITEM,
    RESOURCE_NEW,
    attr,
    el,
    text,
    url_for,
)
from m0_sqlite import (
    Connection,
    Statement,
    install_stamps,
    open,
    open_readonly,
    stamp_floor,
    stamp_head,
    watch,
)

# --- verbatim from apps/table_notes/server.mojo (31fb5841) ---------------------

comptime NOTES = "/notes"
comptime NOTES_NEW = NOTES + RESOURCE_NEW
comptime NOTE = NOTES + RESOURCE_ITEM
comptime NOTE_EDIT = NOTES + RESOURCE_EDIT
comptime NOTES_CHANGES = NOTES + "/changes"
comptime NOTES_EVENTS = NOTES + "/events"
comptime LIST_ID = "notes-list"

comptime NOTES_ID = "notes"
comptime Frag = Fragment[Htmx]

comptime LIST_PAGE = 50


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


def render_list(db: Connection, after: Int, head: Int = -1) raises -> String:
    """The `notes` fragment: `LIST_PAGE` rows after rowid `after`, and a
    link to the rows after those when there are any. With `head`, the
    first page carries the script that keeps it live from that stamp."""
    var f = Frag(NOTES_ID)
    f.raw(el("p", "", el("a", attr("href", NOTES_NEW), "New note")))
    var q = db.prepare("SELECT id, title FROM notes WHERE id > ?1 ORDER BY id LIMIT ?2")
    q.bind_int(1, after)
    q.bind_int(2, LIST_PAGE + 1)
    var items = String()
    var shown = 0
    var last = after
    var more = False
    while q.step():
        if shown == LIST_PAGE:
            more = True
            break
        last = q.column_int(0)
        items += render_item(f, last, q.column_text(1), String(""))
        shown += 1
    f.raw(el("ul", attr("id", LIST_ID), items))
    if shown == 0:
        f.raw(el("p", attr("id", "none-yet"), text("none yet")))
    if more:
        var next = Query()
        next.add("after", String(last))
        var url = next.on(url_for(NOTES))
        f.raw(el("p", "", f.el("a", "get", url, attr("href", url), "More", push=True)))
    if head >= 0:
        f.raw(el("script", "", _FEED_SCRIPT + String(head) + _FEED_SCRIPT_TAIL))
    return f^.finish()



# --- the harness (not from the app) -------------------------------------------
#
# Follow-up 1 adds Wk, Rk, C and Ck. bench_notes_attempt3.mojo is the file
# attempt 3 measured with.


def finish_page(var f: Frag, items: String, shown: Int, last: Int, more: Bool, head: Int) raises -> String:
    """The tail of `render_list`, from the `<ul>` on: the same code."""
    f.raw(el("ul", attr("id", LIST_ID), items))
    if shown == 0:
        f.raw(el("p", attr("id", "none-yet"), text("none yet")))
    if more:
        var next = Query()
        next.add("after", String(last))
        var url = next.on(url_for(NOTES))
        f.raw(el("p", "", f.el("a", "get", url, attr("href", url), "More", push=True)))
    if head >= 0:
        f.raw(el("script", "", _FEED_SCRIPT + String(head) + _FEED_SCRIPT_TAIL))
    return f^.finish()


def render_list_kept(mut q: Statement, after: Int, head: Int) raises -> String:
    """`render_list` with its query kept: `q` is
    `SELECT id, title FROM notes WHERE id > ?1 ORDER BY id LIMIT ?2`."""
    var f = Frag(NOTES_ID)
    f.raw(el("p", "", el("a", attr("href", NOTES_NEW), "New note")))
    q.reset()
    q.bind_int(1, after)
    q.bind_int(2, LIST_PAGE + 1)
    var items = String()
    var shown = 0
    var last = after
    var more = False
    while q.step():
        if shown == LIST_PAGE:
            more = True
            break
        last = q.column_int(0)
        items += render_item(f, last, q.column_text(1), String(""))
        shown += 1
    q.reset()
    return finish_page(f^, items, shown, last, more, head)


comptime STAMP_SQL = "SELECT seq FROM m0_stamp WHERE id = 0"
comptime FLOOR_SQL = "SELECT floor FROM m0_stamp WHERE id = 0"
comptime PAGE_SQL = "SELECT id, title FROM notes WHERE id > ?1 ORDER BY id LIMIT ?2"


def kept_int(mut q: Statement) raises -> Int:
    """One integer from a kept statement, reset at once so no read stays open."""
    q.reset()
    _ = q.step()
    var v = q.column_int(0)
    q.reset()
    return v


struct WholeArm(Movable):
    """W: today's `Notes.first_page`, on its own read-only connection."""

    var reader: Connection
    var rows: Cached
    var rows_head: Int

    def __init__(out self, path: String) raises:
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.rows_head = 0

    def first_page(mut self) raises -> String:
        var now = self.reader.data_version()
        if not self.rows.current(now):
            self.reader.begin()
            try:
                self.rows_head = stamp_head(self.reader)
                var body = render_list(self.reader, 0, self.rows_head)
                self.reader.commit()
                _ = self.rows.fill(now, body^)
            except e:
                self.reader.rollback()
                raise e^
        return self.rows.body


struct WholeKeptArm(Movable):
    """Wk: W with its two statements kept (the stamp's and the page's)."""

    var reader: Connection
    var rows: Cached
    var rows_head: Int
    var q_stamp: Statement
    var q_page: Statement

    def __init__(out self, path: String) raises:
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.rows_head = 0
        self.q_stamp = self.reader.prepare(STAMP_SQL)
        self.q_page = self.reader.prepare(PAGE_SQL)

    def first_page(mut self) raises -> String:
        var now = self.reader.data_version()
        if not self.rows.current(now):
            self.reader.begin()
            try:
                self.rows_head = kept_int(self.q_stamp)
                var body = render_list_kept(self.q_page, 0, self.rows_head)
                self.reader.commit()
                _ = self.rows.fill(now, body^)
            except e:
                self.reader.rollback()
                raise e^
        return self.rows.body


comptime CHANGES_SQL = (
    "SELECT c.row, c.gone, n.title FROM m0_changes c"
    " LEFT JOIN notes n ON n.id = c.row"
    " WHERE c.tbl = 'notes' AND c.seq > ?1"
)
comptime IDS_SQL = "SELECT id FROM notes WHERE id > ?1 ORDER BY id LIMIT ?2"
comptime TITLE_SQL = "SELECT title FROM notes WHERE id = ?1"


def apply_changes[SABOTAGE: Bool](mut q: Statement, mut cache: Dict[Int, String], mut rendered: Int, since: Int, f: Frag) raises:
    """Drop the gone rows stamped above `since`; render again the live ones the cache holds."""
    q.reset()
    q.bind_int(1, since)
    while q.step():
        var id = q.column_int(0)
        if q.column_int(1) == 1 or q.is_null(2):
            if id in cache:
                _ = cache.pop(id)
        elif id in cache:
            comptime if not SABOTAGE:
                cache[id] = render_item(f, id, q.column_text(2), String(""))
                rendered += 1
    q.reset()


def cached_items[KEPT: Bool](
    mut q_ids: Statement, mut q_title: Statement, reader: Connection,
    mut cache: Dict[Int, String], mut rendered: Int, f: Frag,
    mut items: String, mut shown: Int, mut last: Int, mut more: Bool,
) raises:
    """The page's ids in order, each `<li>` from the cache or rendered and kept."""
    q_ids.reset()
    q_ids.bind_int(1, 0)
    q_ids.bind_int(2, LIST_PAGE + 1)
    while q_ids.step():
        if shown == LIST_PAGE:
            more = True
            break
        last = q_ids.column_int(0)
        if last in cache:
            items += cache[last]
        else:
            var title: String
            comptime if KEPT:
                q_title.reset()
                q_title.bind_int(1, last)
                _ = q_title.step()
                title = q_title.column_text(0)
                q_title.reset()
            else:
                var tq = reader.prepare(TITLE_SQL)
                tq.bind_int(1, last)
                _ = tq.step()
                title = tq.column_text(0)
            var li = render_item(f, last, title, String(""))
            rendered += 1
            items += li
            cache[last] = li^
        shown += 1
    q_ids.reset()


struct RowArm[SABOTAGE: Bool, KEPT: Bool = False](Movable):
    """R (Rk with KEPT): each row's `<li>` cached; only the cached rows stamped
    above the cached head are rendered again, and an unmoved stamp keeps the
    page. With SABOTAGE, changed rows are not rendered again. Without KEPT it
    prepares every statement per call, as attempt 3's R did."""

    var reader: Connection
    var rows: Cached
    var rows_head: Int
    var cache: Dict[Int, String]
    var rendered: Int
    """Calls to render_item made."""
    var q_stamp: Statement
    var q_floor: Statement
    var q_changes: Statement
    var q_ids: Statement
    var q_title: Statement
    """Prepared once; used only with KEPT."""

    def __init__(out self, path: String) raises:
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.rows_head = 0
        self.cache = Dict[Int, String]()
        self.rendered = 0
        self.q_stamp = self.reader.prepare(STAMP_SQL)
        self.q_floor = self.reader.prepare(FLOOR_SQL)
        self.q_changes = self.reader.prepare(CHANGES_SQL)
        self.q_ids = self.reader.prepare(IDS_SQL)
        self.q_title = self.reader.prepare(TITLE_SQL)

    def first_page(mut self) raises -> String:
        var now = self.reader.data_version()
        if not self.rows.current(now):
            self.reader.begin()
            try:
                var head: Int
                comptime if Self.KEPT:
                    head = kept_int(self.q_stamp)
                else:
                    head = stamp_head(self.reader)
                if self.rows.filled and head == self.rows_head:
                    # Nothing in the watched table changed: the page stands.
                    self.reader.commit()
                    self.rows.clock = now
                else:
                    var f = Frag(NOTES_ID)
                    if self.rows.filled:
                        var floor: Int
                        comptime if Self.KEPT:
                            floor = kept_int(self.q_floor)
                        else:
                            floor = stamp_floor(self.reader)
                        if self.rows_head < floor:
                            self.cache = Dict[Int, String]()
                        else:
                            comptime if Self.KEPT:
                                apply_changes[Self.SABOTAGE](self.q_changes, self.cache, self.rendered, self.rows_head, f)
                            else:
                                var q = self.reader.prepare(CHANGES_SQL)
                                apply_changes[Self.SABOTAGE](q, self.cache, self.rendered, self.rows_head, f)
                    f.raw(el("p", "", el("a", attr("href", NOTES_NEW), "New note")))
                    var items = String()
                    var shown = 0
                    var last = 0
                    var more = False
                    comptime if Self.KEPT:
                        cached_items[True](self.q_ids, self.q_title, self.reader, self.cache, self.rendered, f,
                                           items, shown, last, more)
                    else:
                        var q = self.reader.prepare(IDS_SQL)
                        cached_items[False](q, self.q_title, self.reader, self.cache, self.rendered, f,
                                            items, shown, last, more)
                    var body = finish_page(f^, items, shown, last, more, head)
                    self.rows_head = head
                    self.reader.commit()
                    _ = self.rows.fill(now, body^)
            except e:
                self.reader.rollback()
                raise e^
        return self.rows.body


@fieldwise_init
struct Entry(Copyable, Movable):
    var title: String
    var li: String


struct ContentArm[SABOTAGE: Bool, KEPT: Bool = False](Movable):
    """C (Ck with KEPT): refills on the clock, as the app does; reads the page's
    ids and titles, as `render_list` does; renders again only the rows whose
    title differs from the one it rendered. No stamp validates anything: the
    stamp is read only for the page's script. With SABOTAGE, every cached row
    is reused whatever its title."""

    var reader: Connection
    var rows: Cached
    var rows_head: Int
    var cache: Dict[Int, Entry]
    var rendered: Int
    var q_stamp: Statement
    var q_page: Statement
    """Prepared once; used only with KEPT."""

    def __init__(out self, path: String) raises:
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.rows_head = 0
        self.cache = Dict[Int, Entry]()
        self.rendered = 0
        self.q_stamp = self.reader.prepare(STAMP_SQL)
        self.q_page = self.reader.prepare(PAGE_SQL)

    def first_page(mut self) raises -> String:
        var now = self.reader.data_version()
        if not self.rows.current(now):
            self.reader.begin()
            try:
                comptime if Self.KEPT:
                    self.rows_head = kept_int(self.q_stamp)
                    var body = content_page[Self.SABOTAGE](self.q_page, self.cache, self.rendered, self.rows_head)
                    self.reader.commit()
                    _ = self.rows.fill(now, body^)
                else:
                    self.rows_head = stamp_head(self.reader)
                    var q = self.reader.prepare(PAGE_SQL)
                    var body = content_page[Self.SABOTAGE](q, self.cache, self.rendered, self.rows_head)
                    self.reader.commit()
                    _ = self.rows.fill(now, body^)
            except e:
                self.reader.rollback()
                raise e^
        return self.rows.body


def content_page[SABOTAGE: Bool](mut q: Statement, mut cache: Dict[Int, Entry], mut rendered: Int, head: Int) raises -> String:
    var f = Frag(NOTES_ID)
    f.raw(el("p", "", el("a", attr("href", NOTES_NEW), "New note")))
    q.reset()
    q.bind_int(1, 0)
    q.bind_int(2, LIST_PAGE + 1)
    var items = String()
    var shown = 0
    var last = 0
    var more = False
    while q.step():
        if shown == LIST_PAGE:
            more = True
            break
        last = q.column_int(0)
        var title = q.column_text(1)
        var reuse = False
        if last in cache:
            comptime if SABOTAGE:
                reuse = True
            else:
                reuse = cache[last].title == title
        if reuse:
            items += cache[last].li
        else:
            var li = render_item(f, last, title, String(""))
            rendered += 1
            items += li
            cache[last] = Entry(title^, li^)
        shown += 1
    q.reset()
    return finish_page(f^, items, shown, last, more, head)


def render_list_timed(db: Connection, head: Int, mut t_sql: Int, mut t_items: Int, mut t_rest: Int) raises -> String:
    """`render_list(db, 0, head)` with timers: the query (prepare and steps,
    and the column reads), the render_item calls, and the rest."""
    var t0 = perf_counter_ns()
    var f = Frag(NOTES_ID)
    f.raw(el("p", "", el("a", attr("href", NOTES_NEW), "New note")))
    var t1 = perf_counter_ns()
    var q = db.prepare("SELECT id, title FROM notes WHERE id > ?1 ORDER BY id LIMIT ?2")
    q.bind_int(1, 0)
    q.bind_int(2, LIST_PAGE + 1)
    var items = String()
    var shown = 0
    var last = 0
    var more = False
    var sql = perf_counter_ns() - t1
    var rend = 0
    while True:
        var a = perf_counter_ns()
        var ok = q.step()
        if not ok:
            sql += perf_counter_ns() - a
            break
        if shown == LIST_PAGE:
            more = True
            sql += perf_counter_ns() - a
            break
        last = q.column_int(0)
        var title = q.column_text(1)
        var b = perf_counter_ns()
        sql += b - a
        items += render_item(f, last, title, String(""))
        rend += perf_counter_ns() - b
        shown += 1
    var t2 = perf_counter_ns()
    f.raw(el("ul", attr("id", LIST_ID), items))
    if more:
        var next = Query()
        next.add("after", String(last))
        var url = next.on(url_for(NOTES))
        f.raw(el("p", "", f.el("a", "get", url, attr("href", url), "More", push=True)))
    if head >= 0:
        f.raw(el("script", "", _FEED_SCRIPT + String(head) + _FEED_SCRIPT_TAIL))
    var out = f^.finish()
    var t3 = perf_counter_ns()
    t_sql += sql
    t_items += rend
    t_rest += (t1 - t0) + (t3 - t2)
    return out^


struct Rng:
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed) * 0x9E3779B97F4A7C15 + 1

    def below(mut self, n: Int) -> Int:
        self.s ^= self.s >> 12
        self.s ^= self.s << 25
        self.s ^= self.s >> 27
        return Int((self.s * 0x2545F4914F6CDD1D) >> 33) % n


def title(mut rng: Rng) -> String:
    comptime ALPHA = "abcdefghijklmnopqrstuvwxyz  &"
    var n = 20 + rng.below(21)
    var s = String(capacity_bytes=n)
    var a = ALPHA.as_bytes()
    for _ in range(n):
        s += chr(Int(a[rng.below(len(a))]))
    return s^


def setup(path: String, mut rng: Rng) raises -> Connection:
    """The app's schema, stamps watched before the load, 10,000 notes, VACUUM."""
    var w = open(path)
    w.begin_immediate()
    w.execute(
        "CREATE TABLE IF NOT EXISTS notes ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  title TEXT NOT NULL,"
        "  body TEXT NOT NULL DEFAULT '')"
    )
    install_stamps(w)
    watch(w, "notes")
    w.execute("CREATE TABLE IF NOT EXISTS other (x INTEGER)")
    w.commit()
    w.execute("PRAGMA recursive_triggers = ON")
    w.begin()
    var ins = w.prepare("INSERT INTO notes (title, body) VALUES (?1, '')")
    for _ in range(10000):
        ins.bind_text(1, title(rng))
        _ = ins.step()
        ins.reset()
    w.commit()
    w.execute("VACUUM")
    _ = w.query_scalar("PRAGMA wal_checkpoint(TRUNCATE)")
    return w^


def pick(w: Connection, hot: Bool, mut rng: Rng) raises -> Int:
    if hot:
        var q = w.prepare("SELECT id FROM notes ORDER BY id LIMIT 1 OFFSET ?1")
        q.bind_int(1, rng.below(LIST_PAGE))
        if q.step():
            return q.column_int(0)
        return -1
    var top = Int(w.query_scalar("SELECT max(id) FROM notes"))
    var q = w.prepare("SELECT id FROM notes WHERE id >= ?1 ORDER BY id LIMIT 1")
    q.bind_int(1, 1 + rng.below(top))
    if q.step():
        return q.column_int(0)
    return top


def write_once(w: Connection, hot: Bool, mut rng: Rng) raises -> Int:
    """One write transaction: 80% update a title, 10% delete, 10% insert. Answers the kind (0, 1, 2)."""
    var r = rng.below(100)
    if r < 90:
        var id = pick(w, hot, rng)
        if r < 80:
            var u = w.prepare("UPDATE notes SET title = ?1 WHERE id = ?2")
            u.bind_text(1, title(rng))
            u.bind_int(2, id)
            _ = u.step()
            return 0
        var d = w.prepare("DELETE FROM notes WHERE id = ?1")
        d.bind_int(1, id)
        _ = d.step()
        return 1
    var i = w.prepare("INSERT INTO notes (title, body) VALUES (?1, '')")
    i.bind_text(1, title(rng))
    _ = i.step()
    return 2


def sorted_copy(xs: List[Float64]) -> List[Float64]:
    var t = xs.copy()
    for i in range(1, len(t)):
        var x = t[i]
        var j = i - 1
        while j >= 0 and t[j] > x:
            t[j + 1] = t[j]
            j -= 1
        t[j + 1] = x
    return t^


def pct(xs: List[Float64], p: Float64) -> Float64:
    var t = sorted_copy(xs)
    return t[min(len(t) - 1, Int(p * Float64(len(t))))]


# --- phase 2: the guarded-stamp arm and the WAL page witness ---------------------

comptime WATCHED_SQL = (
    "SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'notes'"
    " AND name IN ('m0_notes_ai', 'm0_notes_au', 'm0_notes_am', 'm0_notes_ad')"
)


struct GuardedArm(Movable):
    """D2k: the stamp head is trusted only while `watched()` held as of the
    current schema version; a moved schema re-verifies and refreshes once.
    Every refresh is Ck's content-validated assembly."""

    var reader: Connection
    var rows: Cached
    var rows_head: Int
    var cache: Dict[Int, Entry]
    var rendered: Int
    var kept: Int
    var q_stamp: Statement
    var q_page: Statement
    var q_sv: Statement
    var q_watched: Statement
    var sv_seen: Int
    var trusted: Bool

    def __init__(out self, path: String) raises:
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.rows_head = 0
        self.cache = Dict[Int, Entry]()
        self.rendered = 0
        self.kept = 0
        self.q_stamp = self.reader.prepare(STAMP_SQL)
        self.q_page = self.reader.prepare(PAGE_SQL)
        self.q_sv = self.reader.prepare("PRAGMA schema_version")
        self.q_watched = self.reader.prepare(WATCHED_SQL)
        self.sv_seen = -1
        self.trusted = False

    def first_page(mut self) raises -> String:
        var now = self.reader.data_version()
        if not self.rows.current(now):
            self.reader.begin()
            try:
                var sv = kept_int(self.q_sv)
                var keep = False
                if not self.rows.filled or sv != self.sv_seen:
                    self.trusted = kept_int(self.q_watched) == 4
                    self.sv_seen = sv
                elif self.trusted:
                    keep = kept_int(self.q_stamp) == self.rows_head
                if keep:
                    self.reader.commit()
                    self.rows.clock = now
                    self.kept += 1
                else:
                    self.rows_head = kept_int(self.q_stamp)
                    var body = content_page[False](self.q_page, self.cache, self.rendered, self.rows_head)
                    self.reader.commit()
                    _ = self.rows.fill(now, body^)
            except e:
                self.reader.rollback()
                raise e^
        return self.rows.body


comptime _OpaqueMut = Pointer[NoneType, MutUntrackedOrigin]


@always_inline
def _pread(fd: Int, mut buf: List[UInt8], n: Int, off: Int) -> Int:
    return external_call["pread", Int, c_int, _OpaqueMut, Int, Int](
        c_int(fd),
        buf.unsafe_ptr().unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
        n,
        off,
    )


@always_inline
def _le(b: List[UInt8], at: Int, n: Int) -> Int:
    var v = 0
    for i in range(n):
        v |= Int(b[at + i]) << (8 * i)
    return v


@always_inline
def _be32(b: List[UInt8], at: Int) -> Int:
    return (Int(b[at]) << 24) | (Int(b[at + 1]) << 16) | (Int(b[at + 2]) << 8) | Int(b[at + 3])


comptime UNCHANGED = 0
comptime TABLE_CHANGED = 1
comptime CANT_TELL = 2


struct WalWitness(Movable):
    """Which pages the WAL's frames wrote since a covered position.

    The position is the wal-index header's (`-shm`, both copies agreeing):
    its salts, which are the WAL header's raw bytes, mxFrame and page size.
    A frame's page number is the first four bytes of its header, big-endian."""

    var shm: FileHandle
    var wal: FileHandle
    var hdr: List[UInt8]
    var fh: List[UInt8]
    var table: List[Bool]
    """By page number: whether the page is one of the table's (dbstat)."""
    var ok: Bool
    var salt: Int
    var mx: Int
    var page: Int
    var frames_read: Int

    def __init__(out self, path: String) raises:
        self.shm = FileHandle(path + "-shm", "r")
        self.wal = FileHandle(path + "-wal", "r")
        self.hdr = List[UInt8](length=96, fill=0)
        self.fh = List[UInt8](length=16, fill=0)
        self.table = List[Bool]()
        self.ok = False
        self.salt = 0
        self.mx = 0
        self.page = 0
        self.frames_read = 0

    def position(mut self) raises -> Tuple[Bool, Int, Int, Int]:
        """(valid, salt, mxFrame, page size) of the committed WAL, now."""
        for _ in range(1000):
            if _pread(self.shm.handle, self.hdr, 96, 0) < 96:
                return (False, 0, 0, 0)
            var same = True
            for i in range(48):
                if self.hdr[i] != self.hdr[48 + i]:
                    same = False
                    break
            if same:
                if self.hdr[12] == 0:
                    return (False, 0, 0, 0)
                var sz = _le(self.hdr, 14, 2)
                return (True, _le(self.hdr, 32, 8), _le(self.hdr, 16, 4), 65536 if sz == 1 else sz)
        raise Error("the wal-index header's two copies never agreed")

    def verdict[IGNORE_SALT: Bool = False](mut self, now: Tuple[Bool, Int, Int, Int]) raises -> Int:
        """What the frames between the covered position and `now` say."""
        if not self.ok or not now[0]:
            return CANT_TELL
        comptime if IGNORE_SALT:
            if now[2] < self.mx:
                return UNCHANGED
        else:
            if now[1] != self.salt or now[2] < self.mx:
                return CANT_TELL
        var hit = False
        var page = now[3]
        for i in range(self.mx + 1, now[2] + 1):
            if _pread(self.wal.handle, self.fh, 16, 32 + (i - 1) * (24 + page)) < 16:
                return CANT_TELL
            self.frames_read += 1
            comptime if not IGNORE_SALT:
                if _le(self.fh, 8, 8) != now[1]:
                    return CANT_TELL
            var pg = _be32(self.fh, 0)
            if pg == 1:
                return CANT_TELL
            if pg < len(self.table) and self.table[pg]:
                hit = True
        return TABLE_CHANGED if hit else UNCHANGED

    def cover(mut self, now: Tuple[Bool, Int, Int, Int]):
        self.ok = now[0]
        self.salt = now[1]
        self.mx = now[2]
        self.page = now[3]

    def remap(mut self, reader: Connection) raises:
        """The table's pages, in the reader's snapshot."""
        for i in range(len(self.table)):
            self.table[i] = False
        var q = reader.prepare("SELECT pageno FROM dbstat WHERE name = 'notes'")
        while q.step():
            var pg = q.column_int(0)
            if pg >= len(self.table):
                self.table.resize(pg + 1024, False)
            self.table[pg] = True


struct WitnessArm[MODE: Int](Movable):
    """D3k (phase 2) with the phase 3 modes; see the module docstring."""

    var reader: Connection
    var rows: Cached
    var rows_head: Int
    var cache: Dict[Int, Entry]
    var rendered: Int
    var kept: Int
    var changed: Int
    var cant: Int
    var remaps: Int
    var salts: Dict[Int, Bool]
    var last: Int
    """The last decision: UNCHANGED, TABLE_CHANGED or CANT_TELL."""
    var q_stamp: Statement
    var q_page: Statement
    var w: WalWitness

    def __init__(out self, path: String) raises:
        self.reader = open_readonly(path)
        self.rows = Cached()
        self.rows_head = 0
        self.cache = Dict[Int, Entry]()
        self.rendered = 0
        self.kept = 0
        self.changed = 0
        self.cant = 0
        self.remaps = 0
        self.salts = Dict[Int, Bool]()
        self.last = -1
        self.q_stamp = self.reader.prepare(STAMP_SQL)
        self.q_page = self.reader.prepare(PAGE_SQL)
        _ = self.reader.data_version()
        self.w = WalWitness(path)

    def first_page(mut self) raises -> String:
        var now = self.reader.data_version()
        if not self.rows.current(now):
            var pos = self.w.position()
            if pos[0]:
                self.salts[pos[1]] = True
            var v: Int
            if not self.rows.filled:
                v = CANT_TELL
            else:
                comptime if Self.MODE == 3:
                    v = self.w.verdict[True](pos)
                else:
                    v = self.w.verdict(pos)
            comptime if Self.MODE == 1:
                if v == TABLE_CHANGED:
                    v = UNCHANGED
            self.last = v
            if v == UNCHANGED:
                self.rows.clock = now
                comptime if Self.MODE == 2:
                    self.w.cover(self.w.position())
                else:
                    self.w.cover(pos)
                self.kept += 1
                return self.rows.body
            if v == TABLE_CHANGED:
                self.changed += 1
            else:
                self.cant += 1
            self.reader.begin()
            try:
                if v == CANT_TELL:
                    self.w.remap(self.reader)
                    self.remaps += 1
                self.rows_head = kept_int(self.q_stamp)
                var body = content_page[False](self.q_page, self.cache, self.rendered, self.rows_head)
                self.reader.commit()
                _ = self.rows.fill(now, body^)
                comptime if Self.MODE == 2:
                    self.w.cover(self.w.position())
                else:
                    self.w.cover(pos)
            except e:
                self.reader.rollback()
                raise e^
        return self.rows.body


def hpct(hist: List[Int], n: Int, p: Float64) -> Float64:
    var want = Int(p * Float64(n))
    var acc = 0
    for i in range(len(hist)):
        acc += hist[i]
        if acc > want:
            return Float64(i) / 10.0
    return Float64(len(hist)) / 10.0


def touch(path: String) raises:
    var f = FileHandle(path, "w")
    f.write("1")
    f.close()


def truth_page(db: Connection) raises -> String:
    db.begin()
    try:
        var head = stamp_head(db)
        var body = render_list(db, 0, head)
        db.commit()
        return body^
    except e:
        db.rollback()
        raise e^


def run[MODE: Int](db_path: String, ctl: String, seconds: Float64, settle: Bool) raises:
    from std.os import remove
    from std.os.path import exists
    var ready = ctl + "/ready"
    var req = ctl + "/pause.req"
    var ack = ctl + "/paused.ack"
    var stop = ctl + "/stop"
    var waited = 0
    while not exists(ready):
        sleep(0.01)
        waited += 1
        if waited > 3000:
            raise Error("the writer never wrote `ready`")
    var arm = WitnessArm[MODE](db_path)
    var truth = open_readonly(db_path)
    _ = arm.first_page()
    var checks = 0
    var hist = List[Int](length=20001, fill=0)   # 0.1 µs buckets up to 2 ms; the last holds the rest
    var comparisons = 0
    var stale = 0
    var kept_at_cmp = 0
    var ack_timeouts = 0
    var t_end = perf_counter_ns() + Int(seconds * 1e9)
    while perf_counter_ns() < t_end:
        var phase_end = perf_counter_ns() + 50_000_000
        while perf_counter_ns() < phase_end:
            var t0 = perf_counter_ns()
            _ = arm.first_page()
            var b = (perf_counter_ns() - t0) // 100
            hist[min(b, 20000)] += 1
            checks += 1
        touch(req)
        var spins = 0
        while not exists(ack):
            sleep(0.0002)
            spins += 1
            if spins > 10000:
                break
        if not exists(ack):
            ack_timeouts += 1
            remove(req)
            continue
        if settle:
            # protocol B (post-hoc): settle while the writer is paused, then ask for quiet commits
            _ = arm.first_page()
            touch(ctl + "/quiet.req")
            var qs = 0
            while not exists(ctl + "/quiet.ack"):
                sleep(0.0002)
                qs += 1
                if qs > 10000:
                    break
            remove(ctl + "/quiet.req")
        var kept_before = arm.kept
        var body = arm.first_page()
        var t = truth_page(truth)
        comparisons += 1
        if arm.kept > kept_before:
            kept_at_cmp += 1
        if body != t:
            stale += 1
            if stale <= 3:
                print("  STALE at comparison ", comparisons, ": last decision ", arm.last,
                      " (0 unchanged, 1 changed, 2 can't tell)", sep="")
        remove(req)
        while exists(ack):
            sleep(0.0001)
    touch(stop)
    print("mode=", MODE, " checks=", checks, " kept=", arm.kept, " changed=", arm.changed, " cant_tell=", arm.cant,
          " remaps=", arm.remaps, " distinct_salts=", len(arm.salts), " frames_read=", arm.w.frames_read, sep="")
    print("mode=", MODE, " comparisons=", comparisons, " stale=", stale, " kept_at_comparison=", kept_at_cmp,
          " (", Float64(kept_at_cmp) * 100.0 / Float64(max(comparisons, 1)), "%) ack_timeouts=", ack_timeouts, sep="")
    print("mode=", MODE, " check us (every call, the clock's fast path included): median=", hpct(hist, checks, 0.5),
          " p90=", hpct(hist, checks, 0.9), " p99=", hpct(hist, checks, 0.99), sep="")
    var nondegenerate = len(arm.salts) >= 50 and kept_at_cmp * 10 >= comparisons
    print("mode=", MODE, " not degenerate: ", nondegenerate, sep="")
    if MODE == 0:
        if stale > 0:
            print("verdict(mode 0)=C (stale)")
        elif nondegenerate:
            print("verdict(mode 0)=A")
        else:
            print("verdict(mode 0)=pass not met: no stale page, but degenerate (too few comparisons kept)")
    else:
        print("sabotage mode ", MODE, " caught: ", stale > 0, sep="")


def main() raises:
    var args = argv()
    var db_path = String(args[1])
    var ctl = String(args[2])
    var seconds = Float64(atol(args[3]))
    var mode = atol(args[4])
    var settle = len(args) > 5 and String(args[5]) == "B"
    print("protocol=", "B (settle, then quiet commits; post-hoc)" if settle else "A (as pre-registered)", sep="")
    if mode == 0:
        run[0](db_path, ctl, seconds, settle)
    elif mode == 1:
        run[1](db_path, ctl, seconds, settle)
    elif mode == 2:
        run[2](db_path, ctl, seconds, settle)
    else:
        run[3](db_path, ctl, seconds, settle)
