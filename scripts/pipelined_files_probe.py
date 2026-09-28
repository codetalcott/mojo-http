#!/usr/bin/env python3
"""Pipelined file responses to a client slower than the server arrive whole
(SPEC J10).

A `--static` response is two transfers, the head from memory and then the
file by sendfile, and `_finish_response` keeps them in that order. The
write-ready path did not: a head the socket could not take at once was
finished there and went straight to `_after_send`, which reset the slot for
its next request with the file unsent. The client read a head promising
`Content-Length` bytes and then the NEXT response's head where they belonged,
and every response after it was misframed.

It needs the send buffer full at a head, which is exactly what pipelining
gives: every response goes out behind the last, and a client that reads
more slowly than the server answers keeps the buffer full. The server here
runs with a long `--static-cache-control`, so each head is far larger than
its file and larger than the kernel's send low-water mark, and nearly every
stall lands on a head -- on macOS as on Linux. Without that, XNU's sendfile,
which refuses below the low-water mark, left most stalls on a file (19 of
78 stalls were heads, over 20 MB of 5000-byte files, in the run that found
it).

usage: pipelined_files_probe.py PORT PATH FILE [COUNT]
  PATH is the file's URL, FILE its bytes on disk; see `poe smoke-sendfile`
"""

import socket
import sys
import threading
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1])
PATH = sys.argv[2]
WANT = open(sys.argv[3], "rb").read()
COUNT = int(sys.argv[4]) if len(sys.argv) > 4 else 1000

# Left unread this long first, so the server fills both buffers and parks.
STALL = 1.0
# Then read in small pieces with a pause, so the server keeps outpacing the
# client and the buffer keeps filling: every refill is another stall.
CHUNK = 8192
PAUSE = 0.0001


def fail(msg):
    print("pipelined_files_probe: FAIL: " + msg)
    sys.exit(1)


sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
# A small window, so the buffers fill early and stay full.
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
sock.connect((HOST, PORT))
request = ("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % PATH).encode()


def writer():
    try:
        sock.sendall(request * COUNT)
    except OSError as exc:
        print("pipelined_files_probe: the requests could not all be sent: %r" % exc)


threading.Thread(target=writer, daemon=True).start()
time.sleep(STALL)
sock.settimeout(10)

buf = b""
got = 0
head_bytes = 0


def more():
    global buf
    try:
        part = sock.recv(CHUNK)
    except socket.timeout:
        part = None
    if PAUSE:
        time.sleep(PAUSE)
    if not part:
        fail("the connection %s after %d of %d responses"
             % ("stalled" if part is None else "closed", got, COUNT))
    buf += part


while got < COUNT:
    while b"\r\n\r\n" not in buf:
        more()
    head, buf = buf.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    if not lines[0].startswith(b"HTTP/1.1 200"):
        fail("response %d is %r -- a response's body was left out and the "
             "next head read in its place" % (got, lines[0][:60]))
    length = None
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    if length != len(WANT):
        fail("response %d says Content-Length %r, the file is %d bytes"
             % (got, length, len(WANT)))
    while len(buf) < length:
        more()
    body, buf = buf[:length], buf[length:]
    if body != WANT:
        fail("response %d's body is %r, not the file -- its head went out "
             "through the write-ready path and the file after it was never "
             "sent (J10)" % (got, body[:40]))
    head_bytes = len(head)
    got += 1

sock.close()
print("pipelined_files_probe: %d pipelined file responses (heads of %d bytes) "
      "arrived whole" % (got, head_bytes))
