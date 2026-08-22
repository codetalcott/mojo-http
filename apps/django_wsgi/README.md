# django_wsgi

A real Django project with no Mojo in it, served by `m0serve`. This is the
pure conformance row: a request/response cycle through a real framework,
cookies in both directions, a body of all 256 byte values, the prefork path,
and a pass under `wsgiref.validate` (`M0_WSGI_VALIDATE=1`, read by
`djangoproj/wsgi.py`). It also carries the RSS guard — 10,000 requests must
not grow the process by more than 12 MB — that keeps the bridge's leak rule
honest.

```bash
uv run poe serve-django            # build bin/m0serve if needed, serve on :8080
uv run poe smoke-django            # what CI asserts

# The same thing by hand — the shape of serving your own project:
uv run poe build-serve
bin/m0serve djangoproj.wsgi:application --app-dir apps/django_wsgi --port 8080
```

`--app-dir` is prepended to `sys.path` so `djangoproj` imports; the binary
resolves libpython from the `python3` on `PATH`, which is why the poe tasks
run inside the venv that has Django installed. Django is a dev dependency of
this repo for this example only.
