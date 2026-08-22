# wsgi_bare

A plain PEP 3333 callable — no framework, zero third-party imports — served by
`m0serve`. It is the conformance target: with nothing between the server and
the spec, a wrong answer is the server's by construction. `poe smoke-wsgi`
checks the parts of PEP 3333 a framework never exercises (the `write()`
callable, a second `start_response`, multi-chunk iterables, `wsgi.input` read
patterns, the CGI environ transform), and `poe smoke-serve` uses the same app
to exercise the CLI itself. See [docs/WSGI_CONFORMANCE.md](../../docs/WSGI_CONFORMANCE.md).

```bash
uv run poe serve-wsgi-bare         # serve on :8086
uv run poe smoke-wsgi              # PEP 3333 conformance (M0_WORKERS=2 throughout)

uv run poe build-serve
bin/m0serve bareapp.wsgi:application --app-dir apps/wsgi_bare --port 8086 --workers 2
```
