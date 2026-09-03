# Documentation

Pages grouped by what you are trying to do. For the project's current state,
run the command rather than reading a file: `uv run poe milestones` computes
what remains before 1.0 from [SPEC.md](SPEC.md) and the roadmap's Known
issues, and CI prints it on every pull request.

## Start here

| page | what it answers |
|---|---|
| [QUICKSTART.md](../QUICKSTART.md) | **Show me.** Ten minutes from `pip install` to live multi-tab sync from one sync Django file. Every command is executed by CI. |
| [RUNNING.md](RUNNING.md) | **How do I run my app?** Flags, the execution modes and when each applies, what to put in front of it, shutdown and exit codes. |
| [SPEC.md](SPEC.md) | **What can it do, and what proves it?** One row per capability with the CI gate that proves it. The closest thing to a contract. |

## Understanding the design

| page | what it answers |
|---|---|
| [WSGI_VS_ASGI.md](WSGI_VS_ASGI.md) | Why there are two execution modes, in a page: what each is for, what free-threading changes, and where each has a cliff. |
| [WSGI_CONFORMANCE.md](WSGI_CONFORMANCE.md) | Where the WSGI implementation stands against PEP 3333, clause by clause. |
| [ROADMAP.md](ROADMAP.md) | The project's state: milestones, known issues with what retires each, what is not planned and why. |
| [Design notes](ROADMAP.md#design-notes) | The engineering record behind the decisions: long-form, dated, kept as written. |

## Measurements

Records of something measured, with the environment it was measured in. They
are not tutorials, and they age.

| page | what it answers |
|---|---|
| [BENCHMARKS.md](BENCHMARKS.md) | Where m0serve wins and loses against gunicorn, uvicorn and Granian, and how not to be fooled by a server benchmark. |
| [WSGI_PERFORMANCE.md](WSGI_PERFORMANCE.md) | The WSGI and ASGI numbers, rendered from dated artifacts. |
| [SERVER_PERFORMANCE.md](SERVER_PERFORMANCE.md) | The Mojo server's own numbers, without Python in the path. |
| [REAL_APP_VALIDATION.md](REAL_APP_VALIDATION.md) | The soak: this server against Django projects nobody here wrote. |

## The project

| page | what it answers |
|---|---|
| [../CHANGELOG.md](../CHANGELOG.md) | What changed, and when. |
| [RELEASING.md](RELEASING.md) | How a release happens, and the two gates CI cannot run. |
| [../README.md](../README.md) | The repository as a whole, including the Mojo framework m0serve is one package of. |
| [../PROVENANCE.md](../PROVENANCE.md) | Where the code came from, and the licensing record. |

## The Mojo framework

For people building on `mojo-http` directly rather than serving a Python app.

| page | what it answers |
|---|---|
| [FFI_DISTRIBUTION.md](FFI_DISTRIBUTION.md) | What ships in the C-ABI bundle, and the licensing position. |
| [SQLITE_PERFORMANCE.md](SQLITE_PERFORMANCE.md) | m0-sqlite findings: batch writes, `mmap_size`, `json_each`. |
| [sqlite-vtab-feasibility.md](sqlite-vtab-feasibility.md) | Whether virtual tables are reachable from Mojo. |

## This site

Everything here renders to [m0serve.dev](https://m0serve.dev) by
[scripts/docsite.py](../scripts/docsite.py), served by m0serve itself, with
`llms.txt` and a Markdown twin of every page for agents and a sitemap for
crawlers. A new `docs/*.md` must be listed in the generator's page table, or
`check-docs` fails naming it; notes under `docs/notes/` are picked up on
their own. [deploy/site](../deploy/site/README.md) is the deployment.
`spec.json` is generated from `SPEC.md` by `poe render-spec`; edit the tables,
never the JSON.
