# A Mojo mount from somewhere else

`--mount PREFIX=mojo` serves a Mojo handler on pool threads that never touch
Python. The handler is a compile-time type, so no command line can name one
against a prebuilt binary: an application that wants its own Mojo routes
builds its own `m0serve`. This note records how it does that without copying
the entry file, and the one rule the build has to keep.

## The seam

`m0serve.mojo` imports one name:

```mojo
from m0serve_mount import MojoMount
```

`m0serve_mount` is a module, and the build's include path decides which file
it is. `poe build-serve` resolves it from `packages/m0-wsgi/mount/`, where the
demo mount lives (the corpus, `/probe`, `/search`, `/hold`). An application
keeps its own `m0serve_mount.mojo` in a directory of its own and builds with
that directory named instead:

```sh
M0SERVE_MOUNT_DIR=/path/to/app/mojo M0SERVE_OUT=bin/m0serve-app uv run poe build-serve
```

The contract is `struct MojoMount(PoolHandler)`: `make(ctx)` builds each pool
thread's handler on that thread, `func` answers, `shutdown` is told. Anything
else in the module is the application's own. `packages/m0-wsgi/mount_fixture/`
is a complete example: a `Views` table under `Mount(ctx.prefix)`, a path
parameter, per-thread state and a writing view.

## Replace the directory, never add one

With the application's directory and the default both on the include path,
the FIRST root wins and nothing reports the other:

| include order | what the binary served |
|---|---|
| application's directory first | the application's mount |
| application's directory last | the demo mount, from a clean build |
| application's directory only | the application's mount |

The middle row is the failure worth designing out: a binary that builds,
starts and answers, with someone else's routes. So `M0SERVE_MOUNT_DIR`
replaces the default root rather than prepending to it, and a directory with
no `m0serve_mount.mojo` in it is refused before `mojo build` runs. A wrong
path is then an error, not a quiet demo.

## Why the conformance survives leaving the entry file

`PoolHandler` is an app-facing trait, and a conformance declared behind a
`.mojoc` gets no witness table: the handler builds and is never called
([the trait's own record](../../packages/m0-http/lightbug_http/mojo_pool.mojo)).
A module found on an `-I` root is compiled from source together with the entry
file, exactly as the struct was when it lived inside that file.
`smoke-mojo-mount` and `smoke-mojo-mount-hold` passing with the demo in the
module is the measurement, not an inference: both route real requests through
the pool threads the conformance drives.

## The gate

`smoke-mount-seam` (SPEC N14) builds a second binary against the fixture and
checks four things:
- the fixture's routes answer, with the path parameter and per-thread state;
- the demo's `/probe` is 404, so the fixture replaced the demo rather than
  answering beside it;
- a rendered link under the prefix is followed and lands;
- a missing mount module is refused.

It was sabotaged by putting the default directory back on the path beside the
fixture's. That build succeeded, served the demo, and failed the smoke's first
assertion.

## What it does not change

The wheel is still a Python host and nothing more. A Mojo mount is still a
build, and the application needs a Mojo toolchain wherever it builds. This
seam removes the copy of the entry file, not the build.
