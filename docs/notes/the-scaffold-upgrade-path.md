# The scaffold's upgrade path — 2026-09-27

A design note from the engineering record. SPEC N42 is the row and D52 the
decision.

## The question

`m0 new` writes a project once, and nothing touches its files again. Taking
a newer `m0` moved the CLI and the framework's source, and left everything
the scaffold wrote as the older `m0` wrote it. Between `m0` 0.2.0 and 0.3.0,
six of the ten files every template writes changed: `AGENTS.md`,
`deploy/Dockerfile`, `deploy/README.md`, `deploy/fly.toml`, `.gitignore`
and `pyproject.toml`. The Dockerfile is the one that bites. 0.3.0's
installs `libsqlite3-0` in the runtime stage and makes `/app/data` for a
volume; 0.2.0's does neither, so an application that upgrades and adopts
`m0_sqlite` builds an image that cannot open its library. Nothing said so.

The toolchain had a trap of its own. `m0` refuses any `mojo` but the one it
was gated on and names the fix, `uv add --dev 'mojo==Y'`. With `max-core`
installed that command cannot resolve: `max-core` 26.6.0 and `mojo` 1.1.0
each require `mojo-compiler==1.1.0` exactly (PyPI's metadata, read
2026-09-27), so moving `mojo` alone leaves two pins on two compilers.

## What was built

**The doctor names what an upgrade would change.** `m0 doctor` compares
the scaffold's own files with what the running `m0` writes for the
project's name, and names those that differ. The scaffold's own files are
every one `m0 new` writes except the README and `pyproject.toml`, which are
the application's from its first edit. It reports and never fails. A
difference is the application's own edit as often as an older `m0`'s file
(`unotes` edited its Dockerfile, `.dockerignore` and `fly.toml` on its
first deploy), and only the application can tell which. A file the
application removed is not compared. The name comes from `pyproject.toml`,
so a project moved to another directory still matches. The new `m0` is the
only thing that knows what changed, and the doctor is the command an
upgrade already runs, because the toolchain refusal sends you there.

**The toolchain moves in one command.** With `max-core` installed,
`mojo-gated`'s fix names both pins: `uv add --dev 'mojo==Y' 'max-core==Z'`.
Without it, the sentence is unchanged.

## What was not built, and why

There is no `m0 upgrade`. Rewriting a file safely needs a three-way merge:
what the old `m0` wrote, what the application made of it, and what the new
`m0` writes. The first is recorded nowhere, and recording it now would help
only projects written from now on. A rewrite without it either discards the
application's edits or refuses whenever there are any, which is most
deploys. The retiring condition is in D52.

No version stamp is written into the scaffold either. A stamp would make
every upgrade report every file, whatever changed, which is the noise the
content comparison avoids.
