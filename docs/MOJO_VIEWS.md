# Views and fragments

The application layer of `m0_http`: a table of views over one state, HTML
fragments that name their own swap target, one view answering both a page
and a fragment, URLs built from the routes, and signed sessions. The
`views` scaffold uses the table, fragments and the page-or-fragment answer
in three files, and the examples start from it; the `auth` scaffold is the
same list behind a login, on `m0_http.login`.

## Views

A view is a free function:

```mojo
def index(req: HTTPRequest, params: List[String], items: Items) raises -> HTTPResponse
def create(req: HTTPRequest, params: List[String], mut items: Items) raises -> HTTPResponse
```

The table says which kind each is, and the compiler holds it to that:

```mojo
def item_urls() raises -> Views[Items]:
    var v = Views[Items]()
    v.add_loop("GET", "/health", health)
    v.add_read("GET", ITEMS, index)
    v.add_write("POST", ITEMS, create)
    v.add_read("GET", ITEM, detail)
    v.add_write("DELETE", ITEM, delete)
    return v^
```

| registration | the view gets | runs |
|---|---|---|
| `add_read` | the state, borrowed | on a pool thread if there is a pool, else the loop |
| `add_write` | the state, `mut` | the same |
| `add_loop` | no state | on the event loop, never queued |

`add_read` and `add_write` take `on_loop=True` for a view that needs the
state and must run on the loop, which is where a stream is opened.
`params` holds the route's `:name` captures in order. A method the path
does not take is answered 405 with an `Allow` header, and `OPTIONS` on a
registered path 204. A GET route answers HEAD too, the body dropped and its
`Content-Length` kept; a route registered for HEAD itself wins.

There is no middleware and no decorator. A stored view is a plain function
pointer, and a closure is not one. A guard is a function returning
`Optional[HTTPResponse]`, called on the view's first lines:

```mojo
var refused = require_login(req, st)
if refused:
    return refused.take()
```

A table over rows registers the same routes each time, and `resource` is
that registration:

```mojo
comptime ITEMS = "/items"
comptime ITEM = ITEMS + RESOURCE_ITEM         # /items/:id
comptime ITEM_EDIT = ITEMS + RESOURCE_EDIT    # /items/:id/edit

v.resource(
    ITEMS, list=index, new=new_form, create=create, show=detail,
    edit=edit_form, update=update, delete=delete,
)
```

| slot | route | the view |
|---|---|---|
| `list` | `GET /items` | reads |
| `new` | `GET /items/new` | reads |
| `create` | `POST /items` | writes |
| `show` | `GET /items/:id` | reads |
| `edit` | `GET /items/:id/edit` | reads |
| `update` | `PUT /items/:id` and `POST /items/:id/edit` | writes |
| `delete` | `DELETE /items/:id` | writes |

Every slot is optional, and an empty one registers nothing. `update` has
two routes because a plain form cannot PUT: the edit form posts to the URL
it was served from. A view of the other kind takes its route through
`add_read` or `add_write` with the slot left empty.

`form(req)` returns `None` unless the body is `application/x-www-form-urlencoded`,
so a missing form cannot be read as an empty one. The `Form` keeps every
value of a repeated key; `first("title")` is the usual read. Multipart is
not parsed.

A view answers with an `HTTPResponse`, and `reply` builds the usual ones:

| call | answers |
|---|---|
| `reply.html(body)` | 200, `text/html` |
| `reply.json(status, text, body)` | the status and reason phrase given, `application/json`, the body verbatim |
| `reply.redirect(status, location)` | a 3xx with `Location` |
| `reply.no_content()` | 204 |
| `reply.empty(status, text)` | the status, no body |
| `reply.problem(status, title, detail, instance)` | an RFC 9457 `application/problem+json` body; all four arguments are required, and `instance` is the request's path |

`reply.problem` is for a route no browser swaps; an error a person may see
is a fragment with its status ([below](#a-page-or-a-fragment)).
`reply.param_int(s)` reads a `:id` capture, -1 for anything but a number.

## Fragments

A `Fragment` writes its root id once and generates every attribute that
targets it:

```mojo
comptime Frag = Fragment[Htmx]

var f = Frag("items")
f.raw(f.el("form", "post", ITEMS, attr("class", "new"),
    void("input", attr("name", "title")),
    el("button", "", "Add"),
))
return f^.finish()
```

`f.el(tag, verb, url, attrs, children...)` is an element that swaps the
fragment; `f.swap(verb, url)` is the attributes alone, for the builder
style. Application code never types an `hx-` or `data-on:` swap attribute,
and never retypes the id as `#items`.

`push=True` on either makes the swap move the address bar to its URL, so
the view it arrives at — a filtered list, a detail — can be reloaded,
bookmarked and gone back to: `f.el("a", "get", url, attr("href", url),
text(title), push=True)`. Only a `get` is pushed, a pushed URL being one
the browser GETs on reload. htmx asks for it again on back with
`HX-Request-Type: full`, which `page_or_fragment` answers as a document.
`Fragment[Datastar]` refuses a push: Datastar has no history handling, so
a view that needs an address there is a plain link.

Escaping is named at every hole:

| call | for | escapes |
|---|---|---|
| `text(x)` | data inside an element | yes |
| `attr(name, x)` | data inside an attribute; writes the quotes | yes |
| `el`, `void`, `flag` | markup this code wrote | children are taken as given |
| `raw(x)` | markup this code wrote | no |

Request data passed as a bare string is an injection. `String` stays the
currency: a fragment finishes to a `String`.

### Vocabularies

The type parameter is the client library.

**`Fragment[Htmx]`** emits `hx-get`/`hx-post`/…, `hx-target` and `hx-swap`,
for htmx 4. Its verbs are `get`, `post`, `put`, `patch`, `delete` and
`query`. Two htmx 4 behaviours shape an application: every 4xx answer is
swapped, so an error a person may see is a fragment with the right status
(`page_or_fragment(..., status=422)`); and a DELETE's fields travel in the
query string, so a CSRF token on one goes in a header:
`f.el("button", "delete", url, ..., header=csrf_header(token))` writes
`hx-headers` beside the swap. The layer refuses a header name that is not a
token, and a value holding a control byte or a byte outside ASCII.

**`Fragment[Datastar]`** emits `data-on:EVENT="@verb('url')"` with no
target: Datastar morphs a `text/html` answer into the element whose id it
carries. The event follows the element, a form submitting, a field
changing, anything else clicking. The URL sits inside a JavaScript string,
so one carrying `'`, `\`, CR or LF is refused; `url_for` encodes them.
A request header is refused too: Datastar spells one inside the action,
so a Datastar write carries its CSRF token in a field. Datastar 1.0
applies an action's answer only when its status is 200: a 204 does
nothing and any other status is dropped, so an error fragment answered
with a 422 never reaches the page. Keep an invalid submission in the
browser (`required`) and answer a client that bypasses it with
`reply.problem`. Otherwise, moving an application between the two is the
type parameter and the script tag.

**Your own.** `Vocabulary` is a trait an application may conform to:
`swap` writes the attributes, `h.open_kind()` says which element is open,
and a static `verbs()` names the verbs the library takes. The layer refuses
a verb outside that list before `swap` runs.

## A page or a fragment

```mojo
return page_or_fragment(req, render_list(items), Site("shop"))
```

`page_or_fragment` answers the bare fragment to a swap and the whole
document to a navigation, deciding from the request's headers, and names
all five in `Vary`. No view branches on a header.

| header | reading |
|---|---|
| `HX-Request-Type` | decides when present: `partial` a fragment, `full` a document. htmx 4 sends it on every request |
| `Datastar-Request: true` | a fragment |
| `HX-Request: true` | a fragment, unless one of the two below is beside it |
| `HX-History-Restore-Request: true` | a document |
| `HX-Boosted: true` | a document |

The third argument conforms to `PageShell`: a struct whose `wrap(fragment)`
returns the document, called only when a document was asked for. `status=`
sets the status, with its standard reason phrase.

## URLs

A route is a `comptime` constant given to the table and to `url_for`:

```mojo
comptime ITEM = "/items/:id"

v.add_read("GET", ITEM, detail)
var url = url_for(ITEM, String(id))
```

A misspelled constant is a compile error. `url_for` percent-encodes each
value and raises when the count of values is not the pattern's, when a
value is empty, and when one is `.` or `..`: each would reverse to another
route, the last two because a browser resolves a dot segment before it
sends the request.

A query string is `Query`, which encodes names and values the same way:

```mojo
var q = Query()
q.add("q", want.q)          # an empty value is skipped
q.add("page", String(page))
var url = q.on(url_for(ITEMS))   # /items?q=a%20b&page=2
```

`add` writes only what is set, so one filtered view has one address;
`add_empty` writes the pair whose presence is the meaning. A value that
came from a request is encoded byte by byte, so the URL is one
`Datastar.swap` accepts whatever the value held.

`Views[S](Mount("/shop"))` registers every pattern under a prefix, and
`mount.url_for(ITEM, ...)` puts the prefix in front. One `Mount` value does
both, so a table moved under a prefix keeps its links.

## A rendering kept until the data changes

`Cached` keeps one rendering and the clock value it was made at.
`conditional` puts an `ETag` over a response's body and answers 304 to a
GET that names it:

```mojo
def index(req: HTTPRequest, params: List[String], mut st: Store) raises -> HTTPResponse:
    var now = st.reader.data_version()
    if not st.rows.current(now):
        var body = render_rows(st.reader)
        _ = st.rows.fill(now, body^)
    return conditional(req, page_or_fragment(req, st.rows.body, Site("items")))
```

The clock is any number that differs once the data may have. For SQLite it
is `Connection.data_version()`, asked on a connection opened with
`open_readonly` beside the one that writes:

- Render through the connection the clock is asked on, and ask before
  rendering.
- The view fills a cache, so it registers with `add_write`.
- Each thread that serves builds its own state, so each has its own two
  connections and its own `Cached`. They serve what the others wrote, with
  nothing shared but the file.

The tag is a hash of the bytes sent. A page and its fragment have two
tags, and a commit to another table moves the clock and leaves both alone.
`conditional` adds `Cache-Control: no-cache` where the response names no
policy and keeps a policy the response names, and leaves any status but
200 and any method but GET and HEAD as they are. `apps/table_notes` in the
repository is a resource, the clock and the 304 over one SQLite file.

## What changed since a client last asked

The clock says that something was committed. `m0_sqlite`'s stamps say
what:

```mojo
install_stamps(writer)
watch(writer, "items")
```

From then on every row written to `items`, by this program or any other,
has one entry in `m0_changes` with the stamp of its last change (`seq`),
the stamp it was created at (`born`) and whether it was deleted (`gone`).
The rows above a stamp are one query:

```mojo
var q = st.reader.prepare(
    "SELECT c.row, c.seq, c.born, c.gone, i.name FROM m0_changes c"
    " LEFT JOIN items i ON i.id = c.row"
    " WHERE c.tbl = 'items' AND c.seq > ?1 ORDER BY c.seq"
)
q.bind_int(1, since)
```

- The client keeps the highest `seq` it was answered and asks from there.
  The server keeps nothing for it, so any thread answers.
- A client at stamp N has a row when `born <= N`. Send what is above a
  stamp whole: the rule holds only for a stamp that ended an answer.
- `prune_stamps` forgets deleted rows up to a stamp. A client below
  `stamp_floor`, or above `stamp_head`, is told to read everything again.
  Read the floor, the head and the rows in one read transaction.
- A row that was in the table before `watch` appears in no answer until
  it is written.
- `stamp_of(db, "items")` is the highest stamp in one table.
- A process that derives something from the table keeps its place with
  `cursor(db, name)` and `advance(db, name, seq)`, the latter inside the
  transaction that writes what it derived. It registers before its first
  read (`advance` to 0) and deletes its row when it retires; between the
  two, `prune_stamps(db, slowest_cursor(db))` forgets nothing it still
  needs, and a retired process that kept its row stops pruning for good.

Three limits. A writer that uses `INSERT OR REPLACE` or
`UPDATE OR REPLACE` sets `PRAGMA recursive_triggers = ON`, or a row it
displaces is deleted unrecorded. A migration that rebuilds a table drops
the triggers; ask `watched` at startup. The table's key is
`INTEGER PRIMARY KEY` and the table is not `WITHOUT ROWID`. Because a
stamp can be bypassed, keep `Cached` on the clock.

`apps/table_notes` answers `GET /notes/changes?since=N` this way.

## Sessions

`m0_http.session` is a signed cookie and nothing else:
`v1.<kid>.<exp>.<subject>.<tag>`, HMAC-SHA256 over the rest.
`issue_session` signs one, its expiry in Unix seconds (a timestamp in
milliseconds raises rather than issuing a cookie that never verifies),
`verify_session` refuses in the order malformed,
unknown key, bad signature, expired, and `session_cookie_line` builds the
`Set-Cookie`. `csrf_token` is a MAC over the session's own tag, so it needs
no storage. Keys rotate through a ring: a session ends at its expiry, or
when its key leaves the ring.

There is no session store and no password hashing; the application supplies
the identity.

### A login

`m0_http.login` is one user behind that cookie, the glue two applications
wrote the same way by hand:

```mojo
var login = Login.from_env("APP", "shop-session")   # APP_KEY, APP_PASSWORD, APP_SECURE

var session = st.login.session_of(req)                # a view's first lines
if not session.ok:
    return refuse_signed_out(req, LOGIN, render_login(""))
var refused = csrf_refusal(req, form(req), session, url)   # and a write's
if refused:
    return refused.take()
```

- `Login.from_env(PREFIX, cookie)` reads `PREFIX_KEY` (`LOGIN_KEY_MIN`
  bytes at least; `openssl rand -hex 32` makes one), `PREFIX_PASSWORD` and
  `PREFIX_SECURE`, with `PREFIX_KEY_PREV`, `PREFIX_USER` and `PREFIX_TTL`
  optional, and raises naming what is missing or malformed. Read it in `main` before `serve` and exit 78 on the error, so
  `--doctor` refuses what the run would.
- `PREFIX_SECURE` is stated, never assumed: `1` wherever the application
  is served over HTTPS, so the session cookie carries `Secure`, and `0`
  over plain http such as `http://localhost`. The server cannot see the
  scheme a proxy terminated, and a cookie without `Secure` behind an HTTPS
  redirect travels in clear on a visitor's first `http://` request.
- `sign_in(user, password)` is the credential check and the session in one
  call: None for the wrong pair, else `.session` (the subject and CSRF
  token a page renders) and `set_cookie(resp)`. `sign_out(resp)` expires
  the cookie.
- `refuse_signed_out` answers a navigation with a 303 to the login page and
  a swap with a 401 carrying the form.
- `csrf_refusal` answers 403 unless a write carries this session's token:
  the `X-CSRF-Token` header, else the form's `csrf` field, never the query
  string. `csrf_input(token)` and `csrf_header(token)` write the two.
- `no_store(resp)` marks an answer the session chose as not cacheable.

`m0 new NAME --template auth` writes an application on it, and
`apps/fragment_notes` in the repository, the login it was lifted from,
runs on it.

`m0_http.grant` verifies a signed, expiring permission to open one stream
channel, bound to a session cookie. It is how a Python application behind
`m0serve` authorizes a held stream it does not serve itself.

## Streams

A view opens a Server-Sent Events stream by subscribing the connection's
slot to a registry, and must run on the loop (`add_write(...,
on_loop=True)`). Two streams, for two kinds of state:

**A `Feed`** is for a table that remembers what changed
([above](#what-changed-since-a-client-last-asked)). Its event ids are the
application's stamps, the server keeps one number per subscriber, and a
reconnect is the application's own query:

```mojo
def refresh(mut self) raises:              # on the ViewState
    var now = self.reader.data_version()
    if now == self.clock and not self.feed.lagging():
        return
    self.clock = now
    var head = stamp_head(self.reader)
    for slot in self.feed.behind(head):
        var at = self.feed.at(slot)
        var to = at
        var frames = delta_frames(self.reader, at, to)   # the application's
        if to == at:
            self.feed.skip(slot, head)
        else:
            _ = self.feed.send(slot, to, frames)

def tick(mut self, now_ms: Int):           # the trait's: it does not raise
    try:
        self.refresh()
    except e:
        print("feed:", e)

def events(req: HTTPRequest, params: List[String], mut st: Store) raises -> HTTPResponse:
    return st.feed.open(req, "items")      # the next tick sends what it lacks
```

The state forwards `sse_drain_slot`, `sse_is_streaming` and
`sse_slot_disconnected` to the feed. A delta is sent whole: one that
does not fit beside what a slow subscriber still holds waits, the
subscriber is left out of `behind` until its socket drains, and the
next asks from where that subscriber stands. A page that renders the
view again opens its feed again from that rendering's stamp. Below the floor, or at a
number this database never gave, the application answers with the view
whole. `apps/table_notes` does this for its list, with htmx 4's
`htmx.swap` applying each row's `hx-swap-oob`.

**A `DatastarStream`** is for state the server computes and publishes. A
`Producer` ([the host](MOJO_HOST.md)) publishes frames to every worker.
The rules the `live` scaffold follows:

- Every frame is the whole state. A slow reader's outbox drops frames, and
  the next whole frame heals it.
- `DatastarStream(send_latest=True)` gives a new subscriber the newest
  frame at once.
- The registry's capacity is at least `ctx.capacity`.
- What workers and the producer share lives on the `page_slots` page.

A view sends through the same stream:
`st.stream.patch_elements(EVENTS, render_board(st.messages))` numbers one
frame and queues it for this process's subscribers. The view runs
`on_loop=True`, as does every view that reads or writes what the stream
sends, because under `--blocking-threads` each pool thread builds a state
of its own and nothing drains its stream. Other workers' subscribers are
reached through the bus: the handler's `make` calls
`stream.enable_bus(ctx.bus, ctx.worker, ctx.id_addr)` and its
`sse_peer_frame` forwards to `deliver_peer`. `ViewsApp` does not forward
`sse_peer_frame`, so that takes an `AppHandler` of the application's own,
as `apps/datastar_todo` has. The `board` scaffold sends from a view and
keeps its list in one process (`max_workers() -> 1`); `live` sends from a
producer.

## Not built

A template engine, middleware, named route parameters, multipart parsing, a
session store and a password KDF. Each is a row of
[Decisions](DECISIONS.md) with the condition that would retire it. For an
application that needs an ORM, an admin and a form library, Django behind
[m0serve](RUNNING.md) is the answer, and [the ramp](MOJO_RAMP.md) is how
the two share a process.

The capability rows are section N of [Capabilities](SPEC.md).
