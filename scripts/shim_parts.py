"""Price the shim's language-neutral bookkeeping against a whole request.

Drives the extracted shim exactly as scripts/shim_ownership.py does (a real
asyncio loop, a socketpair per channel, a stand-in port), and times the
pieces a Mojo port could take over — datagram decode, the event tuple and
its dispatch, the credit arithmetic — beside the pieces that must stay
Python (create_task, the app's awaits, the done-callback). Numbers feed
docs/notes/shim-language.md; run on an idle machine.

    uv run python scripts/shim_parts.py
"""
import asyncio
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shim_ownership  # noqa: E402

N = 200_000


def bench(label, fn, n=N):
    fn()  # warm
    t0 = time.perf_counter_ns()
    for _ in range(n):
        fn()
    dt = (time.perf_counter_ns() - t0) / n
    print("%-46s %8.0f ns" % (label, dt))
    return dt


class NullPort:
    def __init__(self):
        self.n = 0

    def dispatch(self, ev):
        self.n += 1
        return False

    def flush(self):
        pass


def main():
    src = shim_ownership.shim_source()
    ns = {}
    exec(compile(src, "m0_shim", "exec"), ns)
    loop = asyncio.new_event_loop()
    ns["_loop"] = loop
    port = NullPort()
    ns["_port"] = port
    ns["set_scope_base"]("testhost", 8088)
    sr, sw = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    ar, aw = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    for s in (sr, sw, ar, aw):
        s.setblocking(False)
    ns["asgi_executor_init"](sr.fileno(), ar.fileno())
    exec_put = ns["_exec_put"]

    print("shim bookkeeping, per operation (Python %s)" % sys.version.split()[0])

    # 1. The event tuple + the dispatch call + the flush arm.
    ev = ("job", 7)
    d_put = bench("_exec_put(('job', slot)) [dispatch stub]", lambda: exec_put(ev))
    d_call = bench("port.dispatch(ev) alone [stub]", lambda: port.dispatch(ev))

    # 2. Datagram decode: what _on_submit does per 8-byte job.
    data = (7).to_bytes(8, "little", signed=True)
    d_dec = bench("int.from_bytes(8-byte job)",
                  lambda: int.from_bytes(data, "little", signed=True))
    batch = bytes([4]) + b"".join(
        (i).to_bytes(8, "little", signed=True) for i in range(16))

    def decode_batch():
        for at in range(1, len(batch), 8):
            int.from_bytes(batch[at:at + 8], "little", signed=True)
    d_batch = bench("decode a 16-slot batch datagram", decode_batch)

    # 3. os.read of one datagram off the submit pair.
    def read_one():
        sw.send(data)
        os.read(sr.fileno(), 65546)
    d_read = bench("socket send + os.read of one datagram", read_one)

    # 4. The credit arithmetic a chunk pays (no wait taken).
    credits = ns["_exec_credits"]
    gcredit = ns["_exec_global_credit"]
    inflight = ns["_exec_inflight"]
    credits[3] = 1 << 30
    gcredit[0] = 1 << 30

    def spend():
        credits[3] -= 1024
        gcredit[0] -= 1024
        inflight[3] = inflight.get(3, 0) + 1024
    d_spend = bench("credit spend (3 dict ops)", spend)

    # 5. A whole buffered request through _Cycle on a trivial app.
    async def app(scope, receive, send):
        await receive()
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"hello"})
    ns["_app"] = app
    scope_base = dict(ns["_scope_base"])
    spawn = ns["spawn"]

    def one_request():
        scope = dict(scope_base)
        scope.update({"method": "GET", "path": "/", "raw_path": b"/",
                      "query_string": b"", "http_version": "1.1",
                      "headers": [], "client": None, "state": {}})
        spawn(5, scope, b"")
        loop.run_until_complete(asyncio.sleep(0))
        loop.run_until_complete(asyncio.sleep(0))

    # run_until_complete per request costs what the note says it costs;
    # subtract a bare pair of them.
    def bare_loop():
        loop.run_until_complete(asyncio.sleep(0))
        loop.run_until_complete(asyncio.sleep(0))
    n2 = 20_000
    d_loop = bench("two bare run_until_complete (subtract)", bare_loop, n2)
    d_req = bench("spawn + task run + done (buffered 200)", one_request, n2)
    print()
    print("whole request, Python side, loop overhead removed: %.0f ns"
          % (d_req - d_loop))
    print("of which language-neutral per request:")
    print("  job decode + dispatch tuple: %.0f ns" % (d_dec + d_put))
    print("  done tuple + dispatch:       %.0f ns" % d_put)
    print("  batch decode per slot: %.0f ns" % (d_batch / 16))
    print("  socket read (amortised over a batch of ~3 at c16): %.0f ns"
          % (d_read / 3))
    print("  credit spend per chunk (streams only): %.0f ns" % d_spend)
    print("dispatch call into the stub port: %.0f ns (a real port call is ~70 ns)"
          % d_call)
    loop.close()


if __name__ == "__main__":
    main()
