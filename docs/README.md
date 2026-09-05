# Documentation

Every page, grouped by what it is for. For the project's current state,
`uv run poe milestones` computes what remains before 1.0 from
[SPEC.md](SPEC.md) and the roadmap; CI prints it on every pull request.

## Start here

| page | contents |
|---|---|
| [Quickstart](../QUICKSTART.md) | Live updates between browser tabs from one file of synchronous Django, in five steps. CI runs every command on it. |
| [After the quickstart](QUICKSTART_NEXT.md) | The same application under two workers, in Flask, and under gunicorn. |
| [demo.m0serve.dev](https://demo.m0serve.dev) | The quickstart's two-tab sync, live. [apps/demo](../apps/demo/README.md) is the file, [deploy/demo](../deploy/demo/README.md) the deployment. |
| [Running m0serve](RUNNING.md) | Flags, execution modes, what to put in front of it, shutdown and exit codes. |
| [Capabilities](SPEC.md) | One row per capability with the test that proves it. Also [spec.json](spec.json). |
| [WSGI and ASGI modes](WSGI_VS_ASGI.md) | What each mode is for, what free-threading changes, where each has a cliff. |

## Measurements

Records of something measured, with the environment it was measured in.
They age.

| page | contents |
|---|---|
| [Benchmarks](BENCHMARKS.md) | Against gunicorn, uvicorn and Granian: where m0serve wins, where it loses, and how the numbers were taken. |
| [WSGI and ASGI performance](WSGI_PERFORMANCE.md) | Throughput and tail latency for both paths, rendered from dated artifacts. |
| [Server performance](SERVER_PERFORMANCE.md) | The Mojo server serving Mojo handlers, without Python in the path. |
| [Real applications](REAL_APP_VALIDATION.md) | The server against Django projects nobody here wrote. |

## Project

| page | contents |
|---|---|
| [Changelog](../CHANGELOG.md) | Changes by version. |
| [Roadmap](ROADMAP.md) | Milestones, known issues with what retires each, what is not planned. |
| [Design notes](notes/) | The engineering record: dated, long-form, kept as written. |
| [WSGI conformance](WSGI_CONFORMANCE.md) | PEP 3333, clause by clause. |
| [Releasing](RELEASING.md) | How a release happens, and the two gates CI cannot run. |
| [README](../README.md) | The mojo-http repository as a whole. |
| [Provenance](../PROVENANCE.md) | Where the code came from, and the licensing record. |

## Mojo packages

For building on mojo-http directly rather than serving a Python application.

| page | contents |
|---|---|
| [FFI distribution](FFI_DISTRIBUTION.md) | What the C-ABI bundle ships, and its licensing position. |
| [SQLite performance](SQLITE_PERFORMANCE.md) | m0-sqlite: batch writes, `mmap_size`, `json_each`. |
| [SQLite virtual tables](sqlite-vtab-feasibility.md) | Whether virtual tables are reachable from Mojo. |

## This site

Rendered from these files by [scripts/docsite.py](../scripts/docsite.py)
and served by m0serve at [m0serve.dev](https://m0serve.dev), with
`llms.txt`, a Markdown twin of every page, and a sitemap. A new `docs/*.md`
must be added to the generator's page table or `check-docs` fails naming it;
notes under `docs/notes/` are picked up on their own. `spec.json` is
generated from `SPEC.md` by `poe render-spec`; edit the tables, never the
JSON. [deploy/site](../deploy/site/README.md) is the deployment.
