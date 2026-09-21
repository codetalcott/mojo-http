# Views and fragments

The application layer of `m0_http`: a table of views over one state, HTML
fragments that name their own swap target, one view answering both a page
and a fragment, URLs built from the routes, and signed sessions. The
`views` scaffold uses all of it in three files; the examples below are from
it.

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
registered path 204.

There is no middleware and no decorator. A stored view is a plain function
pointer, and a closure is not one. A guard is a function returning
`Optional[HTTPResponse]`, called on the view's first lines:

```mojo
var refused = require_login(req, st)
if refused:
    return refused.take()
```

`form(req)` returns `None` unless the body is `application/x-www-form-urlencoded`,
so a missing form cannot be read as an empty one. The `Form` keeps every
value of a repeated key; `first("title")` is the usual read. Multipart is
not parsed.

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
query string, so a CSRF token on one goes in a header.

**`Fragment[Datastar]`** emits `data-on:EVENT="@verb('url')"` with no
target: Datastar morphs a `text/html` answer into the element whose id it
carries. The event follows the element, a form submitting, a field
changing, anything else clicking. The URL sits inside a JavaScript string,
so one carrying `'`, `\`, CR or LF is refused; `url_for` encodes them.
Moving an application between the two is the type parameter and the script
tag.

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
value and raises when the count of values is not the pattern's.

`Views[S](Mount("/shop"))` registers every pattern under a prefix, and
`mount.url_for(ITEM, ...)` puts the prefix in front. One `Mount` value does
both, so a table moved under a prefix keeps its links.

## Sessions

`m0_http.session` is a signed cookie and nothing else:
`v1.<kid>.<exp>.<subject>.<tag>`, HMAC-SHA256 over the rest.
`issue_session` signs one, `verify_session` refuses in the order malformed,
unknown key, bad signature, expired, and `session_cookie_line` builds the
`Set-Cookie`. `csrf_token` is a MAC over the session's own tag, so it needs
no storage. Keys rotate through a ring: a session ends at its expiry, or
when its key leaves the ring.

There is no session store and no password hashing; the application supplies
the identity. `apps/fragment_notes` in the repository is the worked login.

`m0_http.grant` verifies a signed, expiring permission to open one stream
channel, bound to a session cookie. It is how a Python application behind
`m0serve` authorizes a held stream it does not serve itself.

## Streams

A view opens a Server-Sent Events stream by subscribing the connection's
slot to a registry, and must run on the loop. A `Producer`
([the host](MOJO_HOST.md)) publishes frames to every worker. The rules the
`live` scaffold follows:

- Every frame is the whole state. A slow reader's outbox drops frames, and
  the next whole frame heals it.
- `DatastarStream(send_latest=True)` gives a new subscriber the newest
  frame at once.
- The registry's capacity is at least `ctx.capacity`.
- What workers and the producer share lives on the `page_slots` page.

## Not built

A template engine, middleware, named route parameters, multipart parsing, a
session store and a password KDF. Each is a row of
[Decisions](DECISIONS.md) with the condition that would retire it. For an
application that needs an ORM, an admin and a form library, Django behind
[m0serve](RUNNING.md) is the answer, and [the ramp](MOJO_RAMP.md) is how
the two share a process.

The capability rows are section N of [Capabilities](SPEC.md).
