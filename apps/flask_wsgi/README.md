# flask_wsgi

The second framework row. A Flask project with no Mojo in it, served by the
same `m0serve` binary as the Django row — which is the claim this directory
exists to make structural: `m0-wsgi` hosts WSGI, not Django. It asserts
nothing of its own; `poe smoke-flask` runs
[`scripts/wsgi_framework_contract.sh`](../../scripts/wsgi_framework_contract.sh),
the assertions every WSGI framework must pass identically, against it.

```bash
uv run poe serve-flask             # serve on :8087
uv run poe smoke-flask             # the shared contract (skips if flask is absent)

uv run poe build-serve
bin/m0serve flaskproj.wsgi:application --app-dir apps/flask_wsgi --port 8087
```
