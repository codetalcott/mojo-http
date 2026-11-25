"""Phase 2 of plan-d63-witness-2026-11-25.md: what a cache rule better than D63 costs.

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
from std.time import perf_counter_ns

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

    def verdict(mut self, now: Tuple[Bool, Int, Int, Int]) raises -> Int:
        """What the frames between the covered position and `now` say."""
        if not self.ok or not now[0]:
            return CANT_TELL
        if now[1] != self.salt or now[2] < self.mx:
            return CANT_TELL
        var hit = False
        var page = now[3]
        for i in range(self.mx + 1, now[2] + 1):
            if _pread(self.wal.handle, self.fh, 16, 32 + (i - 1) * (24 + page)) < 16:
                return CANT_TELL
            self.frames_read += 1
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


struct WitnessArm[SABOTAGE: Bool](Movable):
    """D3k: on a moved clock, keep the page when the witness says no frame since
    the last check wrote a page of `notes`; otherwise (or when it can't tell)
    take Ck's content-validated assembly. The position is read BEFORE the read
    transaction, so the snapshot holds at least what it covers. With SABOTAGE,
    "the table changed" is taken for "unchanged"."""

    var reader: Connection
    var rows: Cached
    var rows_head: Int
    var cache: Dict[Int, Entry]
    var rendered: Int
    var kept: Int
    var remaps: Int
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
        self.remaps = 0
        self.q_stamp = self.reader.prepare(STAMP_SQL)
        self.q_page = self.reader.prepare(PAGE_SQL)
        _ = self.reader.data_version()   # the reader's connection opens the WAL index first
        self.w = WalWitness(path)

    def first_page(mut self) raises -> String:
        var now = self.reader.data_version()
        if not self.rows.current(now):
            var pos = self.w.position()
            var v = self.w.verdict(pos) if self.rows.filled else CANT_TELL
            comptime if Self.SABOTAGE:
                if v == TABLE_CHANGED:
                    v = UNCHANGED
            if v == UNCHANGED:
                self.rows.clock = now
                self.w.cover(pos)
                self.kept += 1
                return self.rows.body
            self.reader.begin()
            try:
                if v == CANT_TELL:
                    self.w.remap(self.reader)
                    self.remaps += 1
                self.rows_head = kept_int(self.q_stamp)
                var body = content_page[False](self.q_page, self.cache, self.rendered, self.rows_head)
                self.reader.commit()
                _ = self.rows.fill(now, body^)
                self.w.cover(pos)
            except e:
                self.reader.rollback()
                raise e^
        return self.rows.body


comptime NARMS = 5


def arm_name(a: Int) -> String:
    var names: List[String] = ["W", "Rk", "Ck", "D2k", "D3k"]
    return names[a]


struct Arms[SAB3: Bool](Movable):
    var w: WholeArm
    var rk: RowArm[False, True]
    var ck: ContentArm[False, True]
    var d2: GuardedArm
    var d3: WitnessArm[Self.SAB3]

    def __init__(out self, path: String) raises:
        self.w = WholeArm(path)
        self.rk = RowArm[False, True](path)
        self.ck = ContentArm[False, True](path)
        self.d2 = GuardedArm(path)
        self.d3 = WitnessArm[Self.SAB3](path)

    def page(mut self, a: Int) raises -> String:
        if a == 0:
            return self.w.first_page()
        if a == 1:
            return self.rk.first_page()
        if a == 2:
            return self.ck.first_page()
        if a == 3:
            return self.d2.first_page()
        return self.d3.first_page()

    def round(mut self, start: Int, mut times: List[List[Float64]], mut bodies: List[String]) raises:
        for j in range(NARMS):
            var a = (start + j) % NARMS
            var t0 = perf_counter_ns()
            var b = self.page(a)
            var t1 = perf_counter_ns()
            times[a].append(Float64(t1 - t0) / 1e3)
            bodies[a] = b^

    def counts(self) -> String:
        return String("D2k kept=", self.d2.kept, " D3k kept=", self.d3.kept, " remaps=", self.d3.remaps,
                      " frames read=", self.d3.w.frames_read)


def new_times() -> List[List[Float64]]:
    var t = List[List[Float64]]()
    for _ in range(NARMS):
        t.append(List[Float64]())
    return t^


def run[SAB3: Bool](path: String, mode: String, seed: Int) raises -> Bool:
    var rng = Rng(seed)
    var w = setup(path, rng)
    var arms = Arms[SAB3](path)
    var hot = mode == "hot"
    var bodies = List[String](length=NARMS, fill=String(""))
    var scratch = new_times()
    arms.round(0, scratch, bodies)
    var times = new_times()
    var bad = List[Int](length=NARMS, fill=0)
    var kinds = List[Int](length=3, fill=0)
    var c0 = arms.counts()
    for i in range(1000):
        kinds[write_once(w, hot, rng)] += 1
        arms.round(i % NARMS, times, bodies)
        for a in range(1, NARMS):
            if bodies[a] != bodies[0]:
                if bad[a] == 0:
                    print("  ", arm_name(a), " first differs after write ", i, sep="")
                bad[a] += 1
    print(mode, " burst: writes update/delete/insert=", kinds[0], "/", kinds[1], "/", kinds[2],
          "  counts before=[", c0, "] after=[", arms.counts(), "]", sep="")
    var med = List[Float64]()
    for a in range(NARMS):
        med.append(pct(times[a], 0.5))
        print(mode, " burst ", arm_name(a), " us median=", med[a], " p90=", pct(times[a], 0.9),
              " pages differing from W=", bad[a], sep="")
    print(mode, " burst ratios: D3k/Ck=", med[4] / med[2], " D2k/Ck=", med[3] / med[2], " W/D3k=", med[0] / med[4], sep="")

    var otimes = new_times()
    var obad = List[Int](length=NARMS, fill=0)
    var oi = w.prepare("INSERT INTO other (x) VALUES (?1)")
    var c1 = arms.counts()
    for i in range(100):
        oi.bind_int(1, i)
        _ = oi.step()
        oi.reset()
        arms.round(i % NARMS, otimes, bodies)
        for a in range(1, NARMS):
            if bodies[a] != bodies[0]:
                obad[a] += 1
    var omed = List[Float64]()
    for a in range(NARMS):
        omed.append(pct(otimes[a], 0.5))
        print(mode, " other-table ", arm_name(a), " us median=", omed[a], " p90=", pct(otimes[a], 0.9),
              " pages differing from W=", obad[a], sep="")
    print(mode, " other-table counts before=[", c1, "] after=[", arms.counts(), "]", sep="")
    print(mode, " other-table ratios: D3k/Rk=", omed[4] / omed[1], " D2k/Rk=", omed[3] / omed[1], " W/D3k=", omed[0] / omed[4], sep="")

    for t in ["ai", "au", "am", "ad"]:
        w.execute(String("DROP TRIGGER IF EXISTS m0_notes_", t))
    arms.round(0, scratch, bodies)
    var first = Int(w.query_scalar("SELECT min(id) FROM notes"))
    var u = w.prepare("UPDATE notes SET title = 'BYPASSED' WHERE id = ?1")
    u.bind_int(1, first)
    _ = u.step()
    arms.round(0, scratch, bodies)
    var stale = String()
    for a in range(NARMS):
        stale += String(" ", arm_name(a), "=", "fresh" if "BYPASSED" in bodies[a] else "STALE")
    print(mode, " bypass check (triggers dropped, then a title updated):", stale, sep="")

    var ok = True
    for a in range(NARMS):
        if bad[a] != 0 or obad[a] != 0:
            ok = False
    return ok


def main() raises:
    var args = argv()
    var path = String(args[1])
    var mode = String(args[2])
    var seed = atol(args[3])
    var sab = String(args[4]) if len(args) > 4 else String("")
    from std.os import remove
    from std.os.path import exists
    for suffix in ["", "-wal", "-shm"]:
        var p = path + suffix
        if exists(p):
            remove(p)
    var ok: Bool
    if sab == "sabotage-d3":
        ok = run[True](path, mode, seed)
    else:
        ok = run[False](path, mode, seed)
    print("gate=", "PASS" if ok else "FAIL", " sabotage=", sab, sep="")
