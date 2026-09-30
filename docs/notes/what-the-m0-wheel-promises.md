# What the m0 wheel promises — 2026-09-29

A design note from the engineering record. D54 and D55 are the decisions;
SPEC G9 and M14 move to `out of scope`.

## The question

The `m0` wheel ships the framework as source: every tracked file of
m0-core, m0-http, the fork, the host, m0-datastar, m0-sqlite and
m0-postgres (D39). A name in one of those trees is something an application
can import, so it reads as something the packages promise. The 2026-09-28
review went through them asking what uses each, and found a set of names
that nothing in the tree calls — not `m0serve`, not the Mojo host, not an
application under `apps/`, not a scaffold template — each with tests of its
own and, in two cases, a place in the documentation:

- `RequestContext` (`request_context.mojo`), a carrier from
  `before_request` to `after_response` that no handler built.
- `check_api_key` (`auth.mojo`), and with it `AppConfig.api_key` and
  `M0_API_KEY`. The configuration read the variable and nothing read the
  field, so no request was ever refused by it; the host's doctor went out
  of its way to leave the key out of its report.
- `ResponseCache` (`response_cache.mojo`), a URL-keyed cache.
- `PatchJournal` and `JournalResult` (`sse/journal.mojo`), a per-URL patch
  journal. `DatastarStream`'s own replay journal is a different thing and
  stays (SPEC I10, I30).
- `negotiate_encoding` and `negotiate_language`, and the free functions
  `wants_html` and `wants_event_stream` in `content_negotiation.mojo`.
  `AcceptResult` and its fields stay; applications read
  `accept.wants_html`.
- FNV-1a and xxHash32 in m0-core's `hashing.mojo`, with the 32-bit hex
  formatter that printed them, and their C-ABI exports `m0_fnv1a`,
  `m0_xxhash32` and `m0_format_hash`. `libm0core` stays, because `m0pub`
  numbers its events through its one other export, `m0_shared_fetch_add`.
- `run_benchmarks.mojo`, m0-core's benchmark, which the review found no
  longer compiled, and its `bench-core` task.
- `m0_sqlite.stats_ints` and its siblings (`reduce.mojo`), whose one user
  was `bench_sqlite.mojo`.

`ResponseCache` and `PatchJournal` are the supports of a Siren/GRAIL
server, and sibling repositories still use copies of them. The owner's
decision of 2026-09-29 is that Siren/GRAIL on m0 is not a product aim.

## What was decided

**The packages ship what the application layer and `m0serve` use.** Each
name above left the tree, with its tests. One moved rather than left:
`stats_ints`, with `ColumnStats`, went into `bench_sqlite.mojo`, so the
aggregate figure in `docs/SQLITE_PERFORMANCE.md` stays reproducible, and
the bench refuses to time an answer that differs from SQLite's own, which
is the check that mattered. SPEC G9, API-key authentication, moved to `out of scope`: an
application authenticates in its own views, with the layer's signed
session and CSRF check (N13, N43) or a grant (I21), and a key checked in
front of the server is a proxy's.

Nothing served changes. `m0serve` never acted on `M0_API_KEY`, and none
of the removed names was reachable from it or from the Mojo host. What
changes is what an application built with the `m0` wheel can import, and
the wheel is a `0.x` preview (D43): an application that imported one of
these names keeps a copy of its own.

## The client

`m0_http.Client` (`client.mojo`), an HTTP/1.1 client over the fork's own
connect, encode and parse, went the same way, with its end-to-end check
and its smoke (SPEC M14). No application called it. It spoke no TLS, so it
could reach almost nothing outside a private network. And it blocked: a
view that runs on the loop and makes a call stalls every connection that
loop holds until the answer comes back, and where a call should run — a
pool thread, or the loop without blocking it — was never decided. A gate
kept it compiling and answering, which is not the same as it being usable.

**Outbound calls are designed later, as a phase of their own** (D55), not
kept alive by a gate on a client nobody used. That design answers TLS,
where the call runs, and connection reuse. The fork is untouched: the
pieces the client assembled stay where they were.

## What would retire it

For D54: Siren/GRAIL returning as a product aim on m0, which brings its
supports back with it; or an application on the layer that needs one of
these names and cannot keep its own copy. For D55: an application on the
layer that needs outbound calls.
