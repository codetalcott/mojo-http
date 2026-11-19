# The server takes its own name — 2026-11-19

> A design note from the engineering record.

The hard fork of lightbug_http in `packages/m0-http/` is renamed
`m0_server`: the directory, the import name, and the package the `m0`
wheel installs (DECISIONS D70). The note holds what was measured of the
fork against its upstream, why the upstream name had become a liability,
what the rename keeps, and what it breaks.

## What is upstream's

Measured on 2026-11-19 at `3654b281`, the last commit before the rename:

- **At most 19% of the fork's code.** By the measure of
  [the-fork-audited](the-fork-audited.md) (`git blame -w -M -C`, a line
  dated before 2026-03-24 counts as inherited), 3,525 of 17,651 code lines
  are inherited. That share was 34% before the 2026-10 review and 23% at
  its end. It is a ceiling: the inherited lines include the 28 private
  commits made before the import (PROVENANCE.md).
- **8% verbatim.** Against upstream v26.1.2 itself (`3aae65f`), 1,000 of
  the fork's 12,038 substantive lines (25 characters or longer, not
  comments) appear anywhere in upstream's 35 Mojo files.
- **Half the files are new.** 35 of the fork's 67 files have no upstream
  counterpart, 11,405 code lines between them: the event loop and its
  `loop/` package, the pool's ring and offload wire, holds, accept sharing,
  descriptor passing. Three upstream files are gone. Upstream's
  `c/socket_error.mojo` declared 145 error types, one per errno, in 2,068
  lines; the fork's is one `SysError` in 37 (review C1).

The program's shape differs too. Upstream's `HTTPService` has one method
and its `Server` a blocking accept loop; the fork's has sixteen (fifteen
with default bodies) and every entry point runs the event loop.

## Why the name went

- **It was the import name.** Every application on the Mojo layer took
  its request and response types from `lightbug_http`, every `m0 new`
  template among them, and the `m0` wheel installed a top-level package of
  that name. Upstream's own `lightbug_http` is still published on the
  modular-community channel (25.4.0, read 2026-11-19). Two packages
  claiming one import name resolve by include order and say nothing,
  the trap CLAUDE.md records for a second mount root.
- **It sent readers to a different program.** Upstream was archived on
  2026-05-12, and its README lists other Mojo libraries to use instead,
  none of them an HTTP server. A person or an agent looking up
  `lightbug_http` finds the API described above, the one the fork left.
- **The `Server` header went first.** Until 1.17.0 the default `Server`
  header named the archived upstream to every client (SPEC F26). The
  import name made the same claim to every reader of an application.

Neither harm was reported: no issue was filed and no agent run is on
record confused by it. The rename was cheapest before the `m0` wheel
leaves preview, since every application written after it would be one
more to edit.

## What it keeps

The MIT licence asks for the notice to travel with the code, not the
name. The directory's `LICENSE` (Copyright (c) 2023 Valentin Erokhin)
stays where it is. `licenses/LICENSE.lightbug_http.txt` keeps its name, as
the text of upstream's licence, and ships in both wheels as before.
NOTICE's entry keeps the upstream, the licence, the copyright and the
modification list, and gains the rename. The README still says the server
is a hard fork of lightbug_http.

History is left as written. The changelog, the design notes, the release
records and the bench artifacts say `lightbug_http` where that was the
name, and so do retired DECISIONS rows.

## What it breaks

Every Mojo application's imports. `from lightbug_http import HTTPRequest`
becomes `from m0_server import HTTPRequest`, and every submodule keeps its
path under the new name (`m0_server.header`, `m0_server.cookie`,
`m0_server.http`, `m0_server.uri`). The types, the module layout and the
include root are unchanged: `-I packages/m0-http` in a checkout, the
wheel's `m0/_mojo/` for an application built by `m0`.

There is no compatibility package. A `lightbug_http` re-exporting
`m0_server` would go on claiming the name the rename gives up. An
application not yet edited fails to compile at its first import, naming
the module, and the changelog carries the one-line edit.

## The name

`m0_server` names what the package is, in the `m0_*` family its
neighbours belong to. It cannot join `m0_http`: the event loop imports
`m0_http.log`, so nothing in `m0_http`'s `src/` may reach it (D33), and
the fork stays a package of its own, resolved from source. No `.mojoc`
carries the name, which matters because a directory beside a `.mojoc` of
its name shadows it.

`m0_wire` was the alternative. `m0_server` sits one letter from `m0serve`,
the Python server's command and PyPI package; the two are never spelled in
the same place, since one is typed at a shell and the other after
`from`.
