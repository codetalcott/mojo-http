"""What becomes of connections that arrive before the application is imported.

    python3 scripts/probes/accept_queue_herd.py M0SERVE N [IMPORT_SECONDS]

m0serve binds and listens, then imports the application; until the import
ends nothing accepts, and what arrives waits in the kernel's accept queue
(SPEC C12: as long as the system allows, 4096 on Linux, 128 on macOS). This
starts M0SERVE on a free port with a WSGI application that sleeps
IMPORT_SECONDS (1.0) as it is imported, opens N connections at once 0.2 s
after the listener returns, and counts each as answered or failed, by where
it failed.

Measured 2026-11-15 against m0serve 1.17.0: Linux 6.8 aarch64 (`somaxconn`
4096) answered all of 1000, 4000 and 6000, the 6000's last answer 2.25 s
after the herd against 0.9 s; macOS 27 (`somaxconn` 128) answered 127 of
1000 and reset 873 at connect.

Not a gate. It needs an open-file limit above N on both sides
(`ulimit -n`), and the Python that M0SERVE embeds needs nothing installed.
"""
import asyncio
import collections
import os
import socket
import subprocess
import sys
import tempfile
import time

APP = '''import time
time.sleep({seconds})


def application(environ, start_response):
    start_response("200 OK", [("Content-Type", "text/plain"), ("Content-Length", "2")])
    return [b"ok"]
'''


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def main(server, n, seconds):
    with tempfile.TemporaryDirectory() as app_dir:
        with open(os.path.join(app_dir, "slowimport.py"), "w") as f:
            f.write(APP.format(seconds=seconds))
        port = free_port()
        proc = subprocess.Popen(
            [server, "slowimport:application", "--app-dir", app_dir, "--port", str(port),
             "--max-connections", str(max(1024, n + 64))],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 20
            while True:
                try:
                    socket.create_connection(("127.0.0.1", port), 0.2).close()
                    break
                except OSError:
                    if proc.poll() is not None or time.monotonic() > deadline:
                        sys.exit("the server did not listen")
                    time.sleep(0.005)
            await asyncio.sleep(0.2)
            t0 = time.monotonic()
            outcomes = collections.Counter()
            answered = []

            async def one():
                writer = None
                try:
                    reader, writer = await asyncio.wait_for(
                        asyncio.open_connection("127.0.0.1", port), 30)
                    writer.write(b"GET / HTTP/1.1\r\nHost: herd\r\nConnection: close\r\n\r\n")
                    data = await asyncio.wait_for(reader.read(-1), 30)
                    if data.startswith(b"HTTP/1.1 200"):
                        outcomes["answered 200"] += 1
                        answered.append(time.monotonic() - t0)
                    else:
                        outcomes["answered, not 200"] += 1
                except (OSError, asyncio.TimeoutError) as e:
                    stage = "at connect" if writer is None else "after connect"
                    outcomes[f"{type(e).__name__} {stage}"] += 1
                finally:
                    if writer is not None:
                        writer.close()

            await asyncio.gather(*(one() for _ in range(n)))
            answered.sort()
            span = (f"; answers from +{answered[0]:.2f} s to +{answered[-1]:.2f} s after the herd"
                    if answered else "")
            print(f"{sys.platform}: {n} connections during a {seconds} s import: "
                  f"{dict(sorted(outcomes.items()))}{span}")
        finally:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1], int(sys.argv[2]),
                     float(sys.argv[3]) if len(sys.argv) > 3 else 1.0))
