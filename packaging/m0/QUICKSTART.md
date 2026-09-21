# Quickstart (Mojo)

A web application written in Mojo: a server-rendered list that htmx 4 swaps
in place, compiled to one binary with no interpreter in it. `m0` writes the
project, builds it against the framework's source, tests it, rebuilds it on
save and builds its deploy image.

macOS arm64 and glibc Linux (x86-64, aarch64). It needs
[uv](https://docs.astral.sh/uv/) and a C compiler named `cc` (Xcode's
command line tools, or `build-essential`); `uv sync` installs the Mojo
toolchain into the project. CI extracts the tagged commands below and runs
them on every pull request (`poe smoke-quickstart-mojo`).

## 1. A project

```bash setup
uvx m0 new shop
cd shop
uv sync
```

`m0 new` writes `./shop` and needs neither a toolchain nor a network.
`uv sync` installs the two packages `pyproject.toml` pins exactly: `m0`, and
the one `mojo` that `m0` release was tested on. The toolchain is a few
hundred megabytes the first time and comes from uv's cache after that.

```text
shop/
  src/server.mojo    main: hands the views table to the host
  src/views.mojo     the state, the views, the URL table
  src/pages.mojo     the routes as constants, the fragment, the document
  test/              test_*.mojo
  smoke.sh           build, serve, probe the wire, stop
  deploy/            Dockerfile, fly.toml
  AGENTS.md          the rules that are not obvious from the code
```

`--template live` writes the other template: a producer thread that pushes
its whole state to every open tab over Server-Sent Events, with Datastar.

## 2. Build and serve

```bash setup
uv run m0 build
```

`src/server.mojo` compiles to `bin/server`.

<!-- observed: docs/notes/the-scaffold.md, "Timings": an M4, the toolchain already in uv's cache -->
The first build takes 13–15 s, a build after an edit 10–13 s, and
`uv run m0 test` 2–4 s, so put logic where a test can reach it.

```bash serve
bin/server --port 8080
```

Open <http://127.0.0.1:8080/>. Add an item, open it, delete it: each is one
request whose answer replaces the `<section id="items">` element. Stop the
server with Ctrl-C.

From a second terminal, in `shop/`:

```bash verify
curl -sf --retry 20 --retry-delay 1 --retry-all-errors http://127.0.0.1:8080/health
echo

# A navigation gets a document. An htmx 4 swap says `HX-Request-Type: partial`
# and gets the fragment alone.
curl -s http://127.0.0.1:8080/items | grep -q '<!doctype html>'
curl -s -H 'HX-Request-Type: partial' http://127.0.0.1:8080/items | grep -q '^<section id="items"'

# A form post answers the list.
curl -s -H 'HX-Request-Type: partial' -d 'title=milk' http://127.0.0.1:8080/items | grep -q 'milk'

# An empty title is a 422 whose body is still the fragment, with the message in it.
code=$(curl -s -o body.html -w '%{http_code}' -H 'HX-Request-Type: partial' -d 'title=' http://127.0.0.1:8080/items)
[ "$code" = 422 ]
grep -q 'role="alert"' body.html
echo "the wire agrees"
```

`./smoke.sh` is these probes as a script, on a port of its own.

## 3. Test

```bash setup
uv run m0 test
```

`m0 test` runs each `test/test_*.mojo` with `mojo run`. It links nothing and
starts no server. A `test_` function added to a file is picked up without
registration. A build does not check a function nothing calls, so a test
that calls it is what vouches for it.

## 4. Doctor

```bash verify
uv run m0 doctor
```

Every toolchain check, then the binary's own `--doctor`: the configuration
it would serve and where each value came from, with nothing bound.
`--json` prints one object for a program to read. A refusal from `m0` or
from the binary is exit 78 and one line naming the fix.

## 5. Rebuild on save

```bash serve
uv run m0 dev -- --port 8080
```

`m0 dev` builds, serves `bin/server` with whatever follows `--`, and watches
`src/` and `pyproject.toml`. On a save it builds while the old server keeps
answering. A build that fails prints the compiler's message and changes
nothing else. A build that succeeds stops the old server and starts the new
binary. Ctrl-C stops both.

Edit the sentence an empty list shows, in `src/pages.mojo`:

```bash verify
curl -sf --retry 60 --retry-delay 1 --retry-all-errors http://127.0.0.1:8080/health > /dev/null
curl -s http://127.0.0.1:8080/items | grep -q 'nothing yet'

sed -i.bak 's/nothing yet/the shelf is empty/' src/pages.mojo && rm src/pages.mojo.bak

# The old server answers until the new build has succeeded.
for i in $(seq 1 90); do
  curl -s --max-time 2 http://127.0.0.1:8080/items | grep -q 'the shelf is empty' && break
  sleep 1
done
curl -s http://127.0.0.1:8080/items | grep -q 'the shelf is empty'
echo "rebuilt and swapped"
```

## 6. An image

```bash
uv run m0 image
docker run --rm -p 8080:8080 shop
```

`m0 image` is `docker build -f deploy/Dockerfile` from the project root,
then the image's own `/app/about.json` as the last line of output. The
compiler runs in the builder stage, so this step needs docker, a committed
`uv.lock`, and no local toolchain. The image holds the binary and the Mojo
runtime libraries and no Python. CI builds this image from a scaffolded
project on x86-64 Linux on every pull request (`poe smoke-scaffold-image`);
the commands above are not among the ones this page's gate runs, because
half of its runners have no docker. [Deploy](../../docs/MOJO_DEPLOY.md) has
the rest, Fly.io included.

## Next

- [The host](../../docs/MOJO_HOST.md): workers, threads, a handler pool,
  flags and the doctor, every refusal.
- [Views and fragments](../../docs/MOJO_VIEWS.md): the views table,
  `Fragment`, the htmx and Datastar vocabularies, pages and fragments from
  one view, URLs, sessions.
- `AGENTS.md` in the project is the short form of both, written for a coding
  agent. `uv run m0 include` prints where the framework's source is
  installed; it is there to be read.
