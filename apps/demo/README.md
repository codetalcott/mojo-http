# demo

The live demo at [demo.m0serve.dev](https://demo.m0serve.dev): open the page
in two browser tabs, type in either, and the other shows it within the
second -- once over a held Server-Sent Events stream and once over a
WebSocket, side by side. Everything is [demoapp.py](demoapp.py), one file of
plain synchronous Django in the quickstart's shape: a view approves a
connection by answering with `M0-Hold` and `M0-Channel`, m0serve holds it,
and `m0pub.publish()` from any view reaches every subscriber on every
worker. The page says which m0serve version is serving it, and each line
says which worker published it and which worker delivered it to this tab,
with the ones that crossed the bus marked and counted -- the claim itself,
rather than two numbers a visitor has to compare.

A stream's worker comes from its `hello`. A socket has no hello (the server
discards a websocket hold's body), so each tab sends its messages as
`{"text", "tab"}` with a random tab id, the view echoes the id, and the tab
learns its socket's worker from its own echo -- the view runs on the worker
holding the socket. Every other tab's socket message reaches it too, on the
same channel, and names a different socket; the page used to take its status
line from those.

What a public page needs that the tutorial does not, and where it lives:

- **Channels namespaced per visitor.** The first load hands the browser a
  random 128-bit token in a cookie; every hold and every publish is scoped
  to `demo/<token>`. Tabs in one browser share it, strangers never do, and
  the hold views answer 403 without it.
- **Limits in the view.** 280 bytes a message (413), 30 messages a minute
  per visitor per worker (429 with `Retry-After`; a refused WebSocket
  message gets one notice on the channel per window instead), a foreign
  `Origin` on an upgrade refused, binary frames dropped, nothing stored.
- **A page that injected markup could not run.** The cookie is `HttpOnly`
  (the script never reads it) and `Secure` whenever Fly's
  `X-Forwarded-Proto` says the request was HTTPS; the CSP allows the one
  inline script and the one stylesheet by sha256, computed at import, with
  no `'unsafe-inline'`.
- **What it does not bound: connections per client.** A token costs one
  cookie-less `GET /`, so the per-visitor limits bound a browser, not a
  script, and nothing here caps how many connections one address holds --
  Fly's `hard_limit` is the ceiling for everyone. A per-address rate in the
  view would not fix it: the application is never told when a hold ends, so
  it can meter approvals but not count what is open, and a rate low enough
  to matter refuses a room full of visitors behind one NAT. It needs a
  server-side cap.
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
a first visitor and its flags, the CSP's hashes against the page's own
inline blocks, the 403s without the cookie, an SSE hold with the view's
`hello` as its head naming the worker `X-Worker` names, one publish
reaching a second stream on the same channel with its tab id and NOT a
stranger's, a WebSocket frame coming back to the socket and the streams,
the page's envelope echoed with its tab id and the socket's own worker, the
413 and the 429. With `--image` it builds the Dockerfile from
the tree's wheel and adds PID 1 and `docker stop`; with `--url` it runs
against anything, including the live site after a deploy.

From the tree the wheel is not installed, so `serve-demo` stages the wheel's
`m0pub.py` as an `m0serve` package on `PYTHONPATH` (the same arrangement
`smoke-flask-realtime` uses) and the version line reads "development tree";
the deploy image is where the version is asserted.
[deploy/demo](../../deploy/demo/README.md) is the deployment.
