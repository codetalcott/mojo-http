# m0serve

A WSGI/ASGI server for Python applications, written in [Mojo](https://www.modular.com/mojo).
Point it at a Django, Flask, FastHTML or Starlette app and it serves it — no
Mojo toolchain required, no compilation step, nothing to configure.

```bash
pip install m0serve
m0serve myproject.wsgi:application
```

The protocol is detected from the object, so the same command serves WSGI and
ASGI. `m0serve --help` lists the flags; `--workers N`, `--threads N` (on
free-threaded CPython) and `--blocking-threads N` are the topology ones.

If something will not start, `m0serve --doctor myproject.wsgi` prints a JSON
report — the interpreter it resolved and the virtualenv it came from, the
spec it discovered, the topology it settled on, and every startup check with
the fix for the ones that failed — and exits with the code the server itself
would have used. It binds nothing and imports nothing twice.

## What is in the wheel

One compiled binary and the Mojo runtime it loads. **No CPython** — m0serve
resolves libpython at run time from the interpreter it is installed beside,
which is why there is no ABI tag and one wheel per platform covers CPython
3.10 through 3.14, free-threaded builds included. It has no Python
dependencies and fetches nothing at install time.

Install it into the same virtual environment as your application, the way you
would gunicorn or uvicorn; the console script points the embedded interpreter
at that environment.

## Platforms

| platform | status |
|---|---|
| macOS arm64 (Apple Silicon) | supported |
| Linux x86_64 (glibc) | supported |
| Linux aarch64 | buildable, not yet shipped |
| macOS x86_64 (Intel) | not possible — Modular ships no Intel Mac toolchain |
| musl / Alpine, Windows | not supported |

The wheel's filename carries the exact macOS and glibc floors it was built
against. On an older system `pip` declines to install it rather than
installing something that crashes.

## Status

Pre-1.0 and deliberately small: HTTP/1.1 only, no TLS, no HTTP/2 — terminate
at a proxy, which is gunicorn's answer too. The API will change before 1.0.

Source, documentation and issues: <https://github.com/codetalcott/mojo-http>

## Licence

MIT, and the wheel redistributes third-party components under their own
terms — the Mojo runtime (Apache-2.0 with LLVM Exceptions) and a fork of
lightbug_http (MIT). Full text and attribution ship inside the wheel; see
`NOTICE.txt` beside the installed package.
