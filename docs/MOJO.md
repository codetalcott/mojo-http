# The Mojo stack

**Preview.** `m0` is `0.x` until an application outside this repository has
run on it in production; its version is separate from m0serve's.

The framework m0serve is built from, for writing the application itself in
Mojo: an HTTP/1.1 server, a router and views, HTML fragments for htmx 4 and
Datastar, Server-Sent Events and WebSockets, SQLite and PostgreSQL bindings
that open their library at run time, and a host that runs them as one
compiled binary. The `m0` package on PyPI carries the framework's source
and a command line that builds against it. MAX is optional beside it,
pinned to the version the host was gated with, for a step that needs
every core.

```bash
uvx m0 new shop
cd shop && uv sync
uv run m0 build && bin/server --port 8080
```

It suits an application whose cost is work on the server per request, per
tick or per connection: a simulation pushed to every open tab, a filtered
scan over data held in memory, thousands of held streams. It has no ORM, no
admin, no template engine and no form library. An application that needs
those is a Django application, and [m0serve](RUNNING.md) serves it;
[the two share a process](MOJO_RAMP.md) when one route needs to be fast.

macOS arm64 and glibc Linux (x86-64, aarch64). Windows and musl are
refused by `m0 doctor`, with no fix to offer.

## Pages

- [Quickstart (Mojo)](../packaging/m0/QUICKSTART.md): a project, a build, a
  served page, tests, rebuild on save, an image. CI runs the page.
- [The host](MOJO_HOST.md): what `main` hands over, workers and threads, a
  handler pool, flags, the doctor, every refusal and exit code.
- [Views and fragments](MOJO_VIEWS.md): the views table, fragments and
  their vocabularies, a page or a fragment from one view, URLs, sessions.
- [Deploy](MOJO_DEPLOY.md): the release build, the image and what it
  measures of itself, Fly.io.
- [From m0serve to Mojo](MOJO_RAMP.md): one views module as a mount inside
  m0serve and as a binary of its own.

## The `m0` command

| command | does |
|---|---|
| `m0 new NAME` | writes a project from the `views` or `live` template; needs no toolchain |
| `m0 build` | `src/server.mojo` to `bin/server`; with the release option, a relocatable `dist/` |
| `m0 test` | runs `test/test_*.mojo`; links nothing |
| `m0 dev` | builds, serves, rebuilds on save; swaps only after a build succeeds |
| `m0 doctor` | the toolchain's checks, then the binary's resolved configuration |
| `m0 image` | the deploy image, then what it measured of itself |
| `m0 include` | where the framework's source is installed |

Its exit codes are a closed set: 0; 1, the tool `m0` ran failed; 2, the
command line cannot be accepted; 78, `m0` refused before running anything,
with one line naming the fix. `m0` runs the `mojo` in its own environment,
never the one on `PATH`, and refuses any version other than the one it was
tested on.

[blobs.m0serve.dev](https://blobs.m0serve.dev) is an application on this
stack: one simulation stepped on the server and streamed to every viewer,
from an image with no interpreter in it.
