# A resource over a table — 2026-10-02

Two applications on the layer's pattern registered the same routes over
every table they served, and one experiment had measured how a rendering
of a table is kept current. This round lifts the first into the table and
the second into two small pieces, and records which parts of the earlier
designs it did not build.

It lands as SPEC N46–N48 and O25 and DECISIONS D60–D62, with
`apps/table_notes` as the application and `smoke-table-notes` as its gate.

## What was asked for

Two things, by two sources.

**The routes.** A CRM read on 2026-09-22 registers five resources, each
with the same nine routes and the same seven handler names;
`apps/fragment_notes` has four of them and the soak application the
reading half. The update is the one with a twin: a plain HTML form sends
GET or POST, so a form answered with a 303 cannot reach a PUT, and both
applications that had an edit form posted it to the form's own URL.

**The clock.** A prototype of 2026-09-30 served a table's rendering with
an `ETag`, re-rendering only when `PRAGMA data_version` had moved. It
settled two things by getting them wrong first. A validator derived from
the clock moves every table's tag on any commit, since the clock is the
database's and not a table's. And a validator with no clock, a size and a
time, answered 304 after an edit that kept the length. So the clock
decides when to look, and a hash of what is sent decides what to say.

## What the review changed

The designs were written before three facts that each removed a part.

**The packages are siblings.** `m0-http` imports `m0-core` and nothing
else; `m0-sqlite` imports nothing. A `Resource` struct holding a table of
views and a connection has no package to live in, and a seventh tree in
the wheel for one struct is not a small pattern. So there is no such
struct. `m0-sqlite` answers the clock as a number,
`Connection.data_version()`. `m0-http` keeps a rendering against a number
(`Cached`) and answers a conditional GET (`conditional`), importing no
database. The application joins them in three lines, and a Postgres clock,
which is a `LISTEN` and not a poll, will hand `Cached` a number of its own.

**The clock needs no commit hook.** `data_version` stands still for a
connection's own writes, and the first design counted those by hand
(`wrote()`), which a caller could forget. Measured on 2026-10-01
([functions-inside-the-query](functions-inside-the-query.md)): a second
connection to the same file, opened read-only, sees the writer's commits
as it sees anyone's, moves for every statement that changes the main file
and for none that does not. A hook over-counts four ways and misses
`VACUUM`. `test_change_clock.mojo` is that table as assertions, on both
CI legs, and D60 is the decision.

Two rules come with a clock read on another connection, and the method's
docstring carries both:

- **Ask on the connection that renders.** A connection holding a read
  open keeps its snapshot and its clock together. A cache filled through
  one connection and stamped with another's clock can pair an old
  rendering with a new value, and then never render again.
- **Ask before rendering.** A commit between the two leaves current rows
  under an old value, which costs one more rendering. The other order
  keeps stale rows under a current value.

**A representation for agents is not this layer's aim.** The prototype
served each table as a binary Siren collection with range requests, and
the design gave the type mapping a rule of its own. Siren on this stack
stopped being a product aim on 2026-09-29, and the encoder is not in this
repository. The representation here is the HTML fragment the layer
already renders.

## What was built

### `Views.resource`

```mojo
comptime NOTES = "/notes"
comptime NOTE = NOTES + RESOURCE_ITEM
comptime NOTE_EDIT = NOTES + RESOURCE_EDIT

v.resource(
    NOTES, new=new_form, create=create, show=detail, edit=edit_form,
    update=update, delete=delete,
)
```

| route | slot |
|---|---|
| `GET /notes` | `list` |
| `GET /notes/new` | `new` |
| `POST /notes` | `create` |
| `GET /notes/:id` | `show` |
| `GET /notes/:id/edit` | `edit` |
| `PUT /notes/:id`, `POST /notes/:id/edit` | `update` |
| `DELETE /notes/:id` | `delete` |

It is a registration. Views stay free functions, an empty slot registers
nothing, and the three suffixes are constants an application joins to its
pattern once, so `url_for` is given the patterns the call registered.

Three things in it are decisions (D61):

- **The slots are typed by the table's rule.** `list`, `new`, `show` and
  `edit` take a view that does not write; `create`, `update` and `delete`
  one that may. A list that fills a cache as it answers is a write, which
  is the case the views module already names ("a GET that bumps a counter
  is ordinary and registers as a write"). It takes the collection's GET
  through `add_write` and leaves the slot empty. `apps/table_notes` is
  written that way on purpose: the alternative was a cache written
  through a borrowed state, which is the thing the two tables exist to
  refuse.
- **No guard in the table.** The first design gave `resource` a `guard=`
  argument. D3 stands: a guard is an early return, and a table that
  carried which routes are private would be a second place to forget.
- **`new` is registered before `show`.** The router answers with the
  first route that matches, and `/notes/:id` matches `/notes/new`.

A nested resource (`/customers/:customer_id/payments`) is registered
under its full pattern and takes the parent's capture as its first
parameter. `Mount` is not the way: it puts its prefix in front verbatim,
so a capture in it would reach the wire unfilled.

### `Connection.data_version`

One pragma, asked on a connection that does not write. It answers a
number to compare for equality, not a count.

### `Cached` and `conditional`

```mojo
def first_page(mut self) raises -> String:
    var now = self.reader.data_version()
    if not self.rows.current(now):
        var body = render_list(self.reader, 0)
        _ = self.rows.fill(now, body^)
    return self.rows.body

return conditional(req, page_or_fragment(req, st.first_page(), Site("notes")))
```

`Cached` is one rendering and the clock value it was made at. `fill`
answers whether the bytes changed, which is what an application that
announces changes would announce.

`conditional` hashes the response's own body. That makes the tag exact
with no scheme for what went into the body: the page and the bare fragment
of one URL have two tags, a deploy that changes the shell changes the
page's tag over the same rows, and nothing the application forgot to
mention can make a 304 stale. What it costs is the wrap and one `wyhash`
on a request that ends in a 304.

It leaves alone what is not its to answer: any status but 200, any method
but GET and HEAD, a file body, a stream. A response the application marked
`no-store` keeps the mark. That is why `apps/fragment_notes` does not use
it: its list carries a session's CSRF token and is not to be kept at all.

## The application

`apps/table_notes` is `fragment_notes`' resource as rows of a SQLite
table, without the login. Each thread that serves builds its own state:
a writer, a read-only reader that every view renders through, and one
`Cached` holding the first page of the list. Nothing is shared but the
file.

That is the property the clock buys. `apps/datastar_todo` serves one list
from two workers by holding SQLite's write lock from a change until its
frame is published, so that frames are numbered in the order their renders
saw the data. Here no worker tells another anything: each asks its own
clock before it answers, so a write through one loop is what the other
serves next, and their tags agree because they hash the same bytes.

Three more rules of the design are the application's, not the layer's:

- **A row has one name.** The id in a URL is the rowid in decimal with no
  sign and no leading zero, so `/notes/07` is a 404 and two URLs never
  answer one row. `reply.param_int` reads `07` as 7, and stays as it is.
  The key is `AUTOINCREMENT`, so one URL never answers two rows either:
  without it SQLite hands the highest rowid to the next insert once its
  row is deleted.
- **A page is what is rendered.** `WHERE id > ?1 ORDER BY id LIMIT n` is
  a continuation that stays stable under inserts and deletes between two
  reads. Only the first page is kept.
- **Forms are plain, and the DELETE is the swap.**

## What it costs, measured

On an M4 over loopback, one Python client on a kept-alive connection,
fifty rows of about 250 bytes each (a 13 KB page), one run:

| request | median |
|---|---|
| conditional GET, clock unmoved, 304 | 57 µs |
| GET, clock unmoved, 200 from the kept rendering | 58 µs |
| conditional GET after a commit to another table: rendered again, 304 | 117 µs |

So a page of fifty rows renders in about 60 µs, and at that size the
cache spares little: the round trip is the cost, and the 304 saves the
13 KB. The prototype's rendering was 34 ms for 5,000 rows unpaged, where
the same check spared two orders of magnitude more. Paging is what keeps
the rendering small, and the cache is what makes an unpaged or expensive
one affordable; an application with fifty cheap rows could render every
time and lose nothing but the bytes.

The clock itself was measured at about a microsecond a poll.

## Not built

- **A change feed.** The prototype polled the clock on the tick and
  published `entity-changed` with the new tag for tables whose bytes had
  changed. `Cached.fill` answers that question; nothing publishes it. It
  needs an application with a stream and a table, and `ViewsApp` forwards
  no stream hooks.
- **A `crud` template.** `m0 new` writes `views`, `live` and `auth`. A
  fourth, on a table, waits for this round to have been used once outside
  the tree.
- **A Postgres clock.** It rides `LISTEN`, which the bus already carries.
  `Cached` takes a number from wherever one comes.
- **A canonical-rowid helper in the layer.** One application wrote it.
- **Rendering by offset**, which would keep an unpaged table lazily.
