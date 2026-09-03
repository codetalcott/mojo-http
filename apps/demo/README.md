# demo

The live demo at [demo.m0serve.dev](https://demo.m0serve.dev): open the page
in two browser tabs, type in either, and the other shows it within the
second -- once over a held Server-Sent Events stream and once over a
WebSocket, side by side. Everything is [demoapp.py](demoapp.py), one file of
plain synchronous Django in the quickstart's shape: a view approves a
connection by answering with `M0-Hold` and `M0-Channel`, m0serve holds it,
and `m0pub.publish()` from any view reaches every subscriber on every
worker. The page says which m0serve version is serving it and which worker
published each line, so a message crossing the bus from one worker to a tab
held by the other is visible.

What a public page needs that the tutorial does not, and where it lives:

- **Channels namespaced per visitor.** The first load hands the browser a
  random 128-bit token in a cookie; every hold and every publish is scoped
  to `demo/<token>`. Tabs in one browser share it, strangers never do, and
  the hold views answer 403 without it.
- **Limits in the view.** 280 bytes a message (413), 30 messages a minute
  per visitor per worker (429 with `Retry-After`; a refused WebSocket
  message gets one notice on the channel per window instead), a foreign
  `Origin` on an upgrade refused, binary frames dropped, nothing stored.
- **The server's own posture** is in the deploy's command line
  ([deploy/demo/Dockerfile](../../deploy/demo/Dockerfile)): `--realtime`,
  two workers, a small `--max-body`, the idle timeout on, `--health-path`,
  `--access-log`, and `M0_SSE_HEARTBEAT_MS=25000` so Fly's proxy does not
  close a quiet held connection.

```bash
uv run poe serve-demo                                     # the tree's binary, two workers, :8190
python3 scripts/demo_probe.py --url http://127.0.0.1:8190 # the demo's promises, from outside
uv run poe smoke-demo                                     # what CI runs: the deploy image, probed
```

The probe ([scripts/demo_probe.py](../../scripts/demo_probe.py)) is the
demo's gate (SPEC M17): the page and its version line, the cookie handed to
a first visitor, the 403s without it, an SSE hold with the view's `hello`
as its head, one publish reaching a second stream on the same channel and
NOT a stranger's, a WebSocket frame coming back to the socket and the
streams, the 413 and the 429. With `--image` it builds the Dockerfile from
the tree's wheel and adds PID 1 and `docker stop`; with `--url` it runs
against anything, including the live site after a deploy.

From the tree the wheel is not installed, so `serve-demo` stages the wheel's
`m0pub.py` as an `m0serve` package on `PYTHONPATH` (the same arrangement
`smoke-flask-realtime` uses) and the version line reads "development tree";
the deploy image is where the version is asserted.
[deploy/demo](../../deploy/demo/README.md) is the deployment.
