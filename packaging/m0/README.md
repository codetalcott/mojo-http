# m0

**Preview.** Write a web application in [Mojo](https://www.modular.com/mojo)
on the [mojo-http](https://github.com/codetalcott/mojo-http) framework: an
HTTP/1.1 server, a router and views, HTML fragments for htmx and Datastar,
Server-Sent Events, SQLite and PostgreSQL bindings that open their library
at run time, and a host that runs the lot as one binary with no
interpreter in it.

This wheel carries the framework's **source** and a small CLI that builds
against it. It is pure Python and installs anywhere; the toolchain it drives
runs on macOS arm64 and glibc Linux (x86-64, aarch64).

```bash
uvx m0 new shop                   # writes ./shop; needs no toolchain and no network
cd shop && uv sync                # the pair it pinned: m0, and the one exact mojo it is gated on
uv run m0 build                   # src/server.mojo -> bin/server, about ten seconds
uv run m0 test                    # mojo run over test/test_*.mojo, two to four seconds a file
uv run m0 dev -- --port 8080      # build, serve, rebuild on save; the old server serves until a build succeeds
uv run m0 doctor                  # the toolchain checks, then bin/server's own --doctor
uv run m0 image                   # docker build of deploy/Dockerfile, then the image's about.json
uv run m0 include                 # where the framework's source is: read it
```

| command | what it does |
|---|---|
| `m0 new NAME [--template views\|live]` | Writes an application into `./NAME`: `src/`, `test/`, a `pyproject.toml` pinning `mojo` and `m0` exactly, `AGENTS.md`, `smoke.sh`, `deploy/`. `views` (the default) is a server-rendered list swapped by htmx 4; `live` is a producer pushing state to every tab over SSE, with Datastar. Exit 2 for a name that is not lowercase letters, digits and hyphens, or a target that is not empty. |
| `m0 build [--release] [--target-cpu CPU]` | Compiles `src/server.mojo` and renames the result onto `bin/server`, so a running server is never written over. `--release` compiles for the platform's baseline CPU, relocates the binary and bundles the Mojo runtime beside it in `dist/` — the directory an image's runtime stage copies. |
| `m0 test [FILE...]` | `mojo run` per file, serial, output untouched. Needs no C compiler. A run with no test files is refused, not passed. |
| `m0 doctor [--json] [-- HOST_ARGS]` | Every check, then `bin/server HOST_ARGS --doctor` with your environment. Exits with the first failed check's code, else the application's. |
| `m0 dev [-- HOST_ARGS]` | Builds and serves `bin/server HOST_ARGS`, then polls `src/` and `pyproject.toml` (stdlib, no watcher). On a change it builds WHILE the old server serves; a failed build leaves it serving; a good one sends it SIGTERM, waits for the pid to exit (6 s, then SIGKILL, named), and starts the new binary. Ctrl-C stops the server and exits 0. |
| `m0 image [--tag T] [--target-cpu CPU] [-- DOCKER_ARGS]` | `docker build -f deploy/Dockerfile -t T DOCKER_ARGS .` from the project root (T defaults to the directory's name), then the image's `/app/about.json` as the last line of stdout. Needs docker and no toolchain. Docker missing or failing is exit 1, its output untouched. It does not deploy. |
| `m0 include` | Prints the include root. |

Exit codes are a closed set: `0`; `1` the tool m0 ran failed; `2` the command
line cannot be accepted; `78` m0 refused before running anything, with one
`m0: detail (fix)` line on stderr.

m0 runs the `mojo` installed in **its own environment** — never the one on
`PATH` — and refuses a version it was not gated on, naming the pin to add.
There is no override: every gate in the repository ran on that one compiler.
MAX is optional and held the same way: `max-core`, if installed, must be
the version the host was gated beside (`m0 doctor`'s `max-gated`).

`m0` is versioned apart from the repository it is cut from, and stays `0.x`
until an application outside that repository has soaked on it.
`m0/_build_info.json` records the tree.

MIT. The `lightbug_http` fork inside is MIT too; both licences are in
`m0/licenses/`.
