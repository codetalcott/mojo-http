# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

`mojo-http` — an HTTP/1.1 server and web framework for Mojo. Extracted from a
private monorepo; see [PROVENANCE.md](PROVENANCE.md).

```
m0-core     (zero deps)   hashing, JSON escape, JSON parse
└── m0-http               router, negotiation, ETag, cache, SSE, auth, CORS, health
    └── lightbug_http     the forked HTTP server (vendored inside m0-http)
m0-datastar               Datastar wire format (zero deps) + server glue (m0-http)
m0-wsgi                   WSGI host — embeds CPython, layers on m0-http
m0-sqlite   (zero deps)   SQLite bindings — a SIBLING, never nested
```

**Zero upward imports.** `m0-core` depends on nothing. `m0-http` uses exactly
three functions from `m0-core` (`wyhash64`, `format_hash64`,
`escape_json_string`). `m0-datastar` splits deliberately: `consts.mojo` and
`sse.mojo` import nothing outside themselves so the wire format is usable
without the framework — do not add an `m0_http` import to either — while
`stream.mojo` and `signals.mojo` are the server glue and may.

`m0-wsgi` is the **only** package that embeds CPython. Keep it that way: a
Python import in `m0-http` or `m0-core` would put libpython on the link line of
every build in the repo. Everything touching the interpreter lives in
`src/bridge.mojo`; the rest of the package works in Mojo types. Two rules the
Mojo 1.0 interop imposes and that the code depends on:

- **`std.python` has no `bytes` bindings at all** — no `PyBytes_*`, no buffer
  protocol, and `PythonObject` has no `Span[Byte]` constructor. Bodies cross as
  raw addresses through `ctypes` (see `bridge.mojo`). Do not "simplify" this to
  a `String` round trip; Mojo strings are UTF-8 and it corrupts every byte above
  0x7F.
- **Mojo never acquires the GIL** except when destroying a `PythonObject`. Every
  other call assumes the calling thread holds it, which is true only because
  `Py_Initialize` leaves it held on the thread that ran `main()`. This is safe
  today purely because the server is single-threaded. If `WorkerSupervisor` is
  ever wired in, **fork before the first Python call, never after.**

`m0-sqlite` imports nothing else here and links the system libsqlite3 — no link
flags on macOS, present-at-link on Linux. `Connection` and `Statement` are
`Movable` but not `Copyable` on purpose: copying would duplicate a handle and
the second destructor would double-free. Do not add `Copyable`.

There is one cycle, and it is intentional: `m0-http/src/{cors,signal,auth,
multiworker}.mojo` import from `lightbug_http`, and `lightbug_http/event_loop.mojo`
imports `m0_http.log`. Both sides live inside `packages/m0-http/`, so the cycle
never crosses a package boundary.

## The lightbug fork

`packages/m0-http/lightbug_http/` is a **hard fork**, not a vendored snapshot.
Upstream was archived 2026-05-12; there is nothing to rebase onto and nowhere to
send patches. Changes there are ordinary changes to this repo.

- Keep it isolated from framework code. Do not refactor it to match framework style.
- Record anything materially new in [NOTICE](NOTICE) — that file is a licensing
  record, not documentation.
- Do not "fix" the `m0_http.log` back-edge by inverting it.

## Commands

```bash
uv run poe                  # list every task
uv run poe build-all        # each package -> .mojoc, in dependency order
uv run poe test-all         # builds first, then runs all tests
uv run poe smoke-hello      # start hello, assert /health, stop
uv run poe smoke-counter    # assert an SSE broadcast reaches a live client
uv run poe test-sqlite      # needs libsqlite3 on the system
```

A `.mojoc` is locked to the exact compiler version that produced it. After any
toolchain change run `build-all`, or you get:

```
Mojo precompiled file is incompatible with the current version of the Mojo compiler
```

The VS Code LSP resolves cross-package imports through these same files, so
stale artifacts appear as unresolved imports in the editor. If *every* prelude
type (`String`, `List`, …) reports "unable to locate module 'std'", the LSP is
running a different Mojo than `uv.lock` pins — that is an editor problem, not a
code problem; check with the compiler before believing it.

## Mojo 1.0 patterns

This project targets **Mojo 1.0** (pinned in `uv.lock`).

1. **`comptime` constants** — replaces deprecated `alias` for compile-time values
2. **No `@value` decorator** — removed in 26.3; structs auto-derive copy/move
3. **Explicit `__init__`** — memberwise init must be written explicitly
4. **`from std.` imports** — implicit stdlib imports deprecated
5. **`String.as_bytes()`** — `s[i]` indexing removed; use `s.as_bytes()[i]` or `s[byte=i]`
6. **`Writable` over `Stringable`** — always add `write_to` when migrating
7. **`Variant` for tagged unions** — `from std.utils.variant import Variant`
8. **`Optional[T]`** — requires `ImplicitlyCopyable`
9. **Parallel arrays (SoA)** — used to work around `ImplicitlyCopyable` constraints
   on `List[Struct]`. Prefer parallel `List` fields over `List[Struct]`; this is
   why `SSERegistry` and `PatchJournal` look the way they do.

## Design principles

- **Functional core / imperative shell** — pure logic in Mojo, I/O at the edges.
- **Content negotiation stays format-agnostic.** `AcceptResult` knows the four
  standard media types; everything else is a caller-supplied vendor type. Do not
  add a vendor media type to `content_negotiation.mojo` — that is exactly the
  coupling this repo was split out to remove.
- **`*/*` resolves to JSON only**, and vendor types must be named exactly. A
  plain `curl` sends `Accept: */*`; it should not receive an opaque binary.

## Mojo reference (fetch on demand)

- Changelog: https://docs.modular.com/mojo/changelog
- Ownership: https://docs.modular.com/mojo/manual/values/ownership
- Structs: https://docs.modular.com/mojo/manual/structs/
- Traits: https://docs.modular.com/mojo/manual/traits
- Collections: https://docs.modular.com/mojo/std/collections/
