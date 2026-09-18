# The host leaves the fork — 2026-09-18

DECISIONS D28 put `host.mojo` beside `mojo_pool.mojo` in the hard fork,
because on Mojo 1.0 an application could not conform to a trait behind a
`.mojoc` built from a directory named other than its package. Mojo 1.1.0
fixed that and the pin moved the same day
([the-pin-moves-to-1-1-0](the-pin-moves-to-1-1-0.md)). D28's retiring
condition then read "moving `host.mojo` and `mojo_pool.mojo` into `src/`".
This is the record of that round. One of the two files went where the
condition said. The other could not, and the reason is a second constraint
that the first had been hiding.

## The probe

`check-mojoc-trait`'s `mismatch` arm conforms an application struct to
`m0_http.fragment.PageShell`. That is the shape of `AppHandler`, and it is
not `AppHandler`. So before anything was committed, the host was compiled
into a throwaway package (`mojo precompile` of a directory holding
`host.mojo`, to `m0_host.mojoc`), and `apps/host_check` — a handler
conforming to `AppHandler` and a producer conforming to `Producer` — was
built against it with its one import line changed.

| step | result |
|---|---|
| `host.mojo` precompiled as its own package, after `m0_http` | compiles |
| `apps/host_check` built against that `.mojoc` | compiles, 716 KB |
| the binary, one request | `200`, body `host_check` |

Both conformances cross a `.mojoc` boundary on 1.1.0 and the witness tables
exist at run time. `PoolHandler` has the same evidence in the tree as it
now stands: `m0serve.mojo`'s `MojoMount` and `HoldMount`, the mount modules
and `apps/pool_spike` all conform to it through `m0_http.mojoc`, gated by
`smoke-mojo-mount`, `smoke-hold-mount`, `smoke-mount-seam` and `build-apps`.

## What `src/` cannot hold

`host.mojo` moved into `src/` does not build:

```
Imported from src/host.mojo:147:
lightbug_http/event_loop.mojo:57:6: error: invalid Mojo precompiled file
'.../packages/m0-http/m0_http.mojoc': invalid magic bytes
from m0_http.log import log_access
```

The host calls `run_event_loop`. `event_loop.mojo` imports `m0_http.log` —
the fork's one standing back-edge, which CLAUDE.md says not to invert — and
`m0_http.log` resolves through `m0_http.mojoc`. That is the file `mojo
precompile src -o m0_http.mojoc` has open for writing while it compiles
`src/host.mojo`. From a clean checkout there is nothing there; after a
build there is a truncated file. The cycle `src/` → `event_loop.mojo` →
`m0_http.mojoc` has no first build.

Two ways round it were tried, because `src/` already imports
`lightbug_http` (whose `server.mojo` reaches the loop) and builds:

| attempt | result |
|---|---|
| `from lightbug_http.event_loop import run_event_loop` moved inside `_run_loop[H]`, as `Server.serve_nonblocking` has it | same error, reported from the local import's line |
| a fork-side `serve_on_loop[T]` holding the local import, called from `src/host.mojo` | same error, reported through `server.mojo` |

A precompile parses every body it reaches, local imports included.
`Server.serve_nonblocking`'s local import works only because nothing in
`src/` calls that method. So the rule is wider than the host: **nothing in
`src/` may reach `event_loop.mojo`**, at any depth, for as long as
`event_loop.mojo` imports `m0_http.log`.

The placement on Mojo 1.0 was therefore over-determined. The witness-table
bug was the recorded reason; this one would have stopped the move on its
own, and nothing had ever asked.

## What was built

**`mojo_pool.mojo` is in `src/`**, exported from `m0_http` (`MojoPool`,
`PoolContext`, `PoolHandler`, `JOIN_TIMEOUT_NS`). It names the
`OffloadPool` and the hold seam, never the loop, and it builds. Its import
of `m0_http.threads` became `.threads`.

**`host.mojo` is a package of its own, `m0_host`**, at
`packages/m0-http/m0_host/`. It sits above the fork and above `m0_http` and
is imported by neither, so its six `m0_http` imports are ordinary downward
ones through the `.mojoc`. It is resolved from SOURCE, as the fork is: the
directory carries the package's name, every task already passes `-I
packages/m0-http/`, and no `m0_host.mojoc` is built or kept — a directory
beside a `.mojoc` of the same name shadows it, which is the trap CLAUDE.md
records for renaming `src/`. Three things follow from source resolution:

- `sabotage-host`'s smoke-gated rules edit `host.mojo` and run a
  smoke with no rebuild between, as they did in the fork. Behind a `.mojoc`
  each rule would have needed a precompile first.
- An edit to the host reaches an application at its next build. An edit to
  `mojo_pool.mojo` now does NOT, until `build-http` runs — and reaches
  `bin/m0serve` only after `build-http`, `build-wsgi` and `build-serve`.
  That is the opposite of the habit formed while the file was in the fork.
- Lazy method bodies have the blind spot the fork's had, so `poe
  check-host-package` compiles `m0_host` whole and throws the artifact
  away, inside `test-all` beside `check-fork-package`.

The fork's imports of `m0_http` went from eight, in three files, to one:
`event_loop.mojo` → `m0_http.log`.

## The import paths, decided

The handoff named two shapes: a clean move, or a move with the fork's
`__init__.mojo` still re-exporting the old names. A re-export is an import,
so the second keeps the edge the move exists to remove. The clean move was
chosen, on these grounds:

- `lightbug_http.host` was never in a release. The host landed after
  1.4.0, so its path changes inside one `[Unreleased]` section.
- `from lightbug_http import PoolContext, PoolHandler` WAS released, in
  1.4.0, as the mount module's authoring surface (SPEC N14). It now reads
  `from m0_http import PoolContext, PoolHandler`. The served contract
  CHANGELOG states — `m0serve`'s flags and environment, the two hold
  headers, `m0pub.publish()` — does not include a Mojo import path, and a
  mount module is compiled against the tree it is built with, so the break
  is a compile error naming the missing name at the build that adopts the
  new tree. It is recorded under Changed.
- No application outside this repository supplies a mount module:
  textshelf, the one production consumer, has no `.mojo` file.

## What `apps/pool_spike` still guards

`build-apps` compiling `apps/pool_spike` was the guard against moving
`mojo_pool.mojo` into `src/`: on 1.0 the app's `PoolHandler` conformance
failed there. The direction has reversed and the guard with it — the same
compile now fails if a toolchain takes the witness-table fix away, for the
real trait rather than `check-mojoc-trait`'s `PageShell`.

## What was not done

- **The `m0_http.log` back-edge stands.** Removing it would let the host
  into `m0_http` and end the cycle altogether. It is its own decision, the
  standing instruction is against it, and D33 records the constraint it
  now imposes.
- **D12 and D7** — `page_or_fragment` taking a `PageShell`, and
  `Vocabulary` opened to an application's conformance — are unblocked by
  the same pin and are each a round of their own. Neither touches the
  loop, so neither meets the constraint above.
