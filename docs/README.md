# The documentation, and what each page is for

**For the project's current state, run the command — not a file:**

```bash
uv run poe milestones
```

It computes what remains between here and 1.0 from `SPEC.md`, ROADMAP's
Known issues and the soak record, so it cannot disagree with them. CI prints
it on every pull request. Nothing here is a hand-maintained status page,
deliberately: this repo has watched a Known issue outlive its fix by a
release and a soak record go five minor versions stale, both unnoticed.

## Start here

| page | what it answers |
|---|---|
| [SPEC.md](SPEC.md) | **What can this server do, and what proves it?** One row per capability, each naming the gate that proves it and the cadence it runs on. Its own generated rollup carries the counts. The closest thing to a contract. |
| [ROADMAP.md](ROADMAP.md) | **Why is it like this?** The narrative record — what was built and measured, what was refused and on what grounds, what is planned, what is broken. Append-mostly; read it for reasoning, not for state. |
| [../CHANGELOG.md](../CHANGELOG.md) | **What changed, and when?** |

`ROADMAP.md` is long. Its `## Milestones` section holds the beta and 1.0
definitions; its `## Known issues` and `## Recently resolved` are the live
and retired defect lists.

## Doing the work

| page | what it answers |
|---|---|
| [RELEASING.md](RELEASING.md) | How a release happens — and the two pre-release gates CI structurally cannot run. |
| [REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md) | The soak: this server against Django projects nobody here wrote. A 1.0 requirement, because every app in `apps/` was written to test this server. |
| [WSGI_CONFORMANCE.md](WSGI_CONFORMANCE.md) | Where the WSGI implementation stands against PEP 3333, clause by clause. |
| [FFI_DISTRIBUTION.md](FFI_DISTRIBUTION.md) | What ships in the C-ABI bundle, and the licensing position. |

## Measurements

Each of these is a record of something measured, with the environment it was
measured in. They are not tutorials and they age.

| page | what it answers |
|---|---|
| [WSGI_VS_ASGI.md](WSGI_VS_ASGI.md) | Which execution mode to choose, and the cliffs in each. |
| [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md) | The WSGI/ASGI numbers, rendered from `bench/results/`. |
| [SERVER_PERFORMANCE.md](SERVER_PERFORMANCE.md) | The Mojo server's own numbers, without Python in the path. |
| [BENCHMARKS.md](BENCHMARKS.md) | How to run the benchmarks, and how not to be fooled by them. |
| [SQLITE_PERFORMANCE.md](SQLITE_PERFORMANCE.md) | m0-sqlite findings — batch writes, `mmap_size`, `json_each`. |
| [sqlite-vtab-feasibility.md](sqlite-vtab-feasibility.md) | Whether virtual tables are reachable from Mojo. |

## Generated, not edited

`spec.json` is rendered from `SPEC.md` by `scripts/spec_sheet.py` (`poe
render-spec`). Edit the tables in `SPEC.md`; never this file.
