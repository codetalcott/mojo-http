# __M0_APP__

A web application in Mojo on the [m0](https://m0serve.dev) framework: one
compiled binary, no Python at run time.

```sh
uv sync                      # the pinned mojo toolchain and m0, into .venv
uv run m0 build              # src/server.mojo -> bin/server (~10 s after an edit)
bin/server --port 8080       # serve; http://localhost:8080
```

Or, while editing: `uv run m0 dev -- --port 8080` builds, serves, and
rebuilds on every save. The running server is replaced only by a build
that succeeded.

```sh
uv run m0 test               # test/test_*.mojo, 2–4 s: the fast loop
uv run m0 doctor             # toolchain checks + the binary's resolved configuration
./smoke.sh                   # build, serve, probe the wire, stop
uv run m0 image              # the deploy image (docker), and what it measured of itself
```

The routes are the docstring of `src/server.mojo`. `AGENTS.md` is the rules
that are not obvious from the code, written for a coding agent and as
useful to a person. `deploy/README.md` is the way to an image and to Fly.io.

Commit `uv.lock`: it is what makes the next checkout the same toolchain.

## Editor

The Mojo VS Code extension resolves imports through `mojo.lsp.includeDirs`,
which takes absolute paths and passes them on unexpanded — so it is a
setting for your machine, not a file in this repository. In
`.vscode/settings.json` (ignored by git):

```json
{ "mojo.lsp.includeDirs": ["<output of: uv run m0 include>", "<this directory>/src"] }
```
