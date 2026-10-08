#!/usr/bin/env python3
"""A reference for the differential corpus: an h11 server answering each
request with what h11 parsed, as `apps/request_echo` answers with what this
server parsed (SPEC B25).

h11 is a strict RFC 9112 parser, and in the dev venv already (uvicorn's
dependency, locked in uv.lock). A request h11 refuses is answered with the
status h11 suggests and closed. Never run by CI: `poe freeze-differential`
starts it to record the table's `h11` column, which is for reading a row.

    python3 scripts/differential_echo_h11.py PORT
"""
import json
import socket
import sys
import threading

import h11


def hx(raw):
    return bytes(raw).hex()


def answer(conn, h, *events):
    for event in events:
        conn.sendall(h.send(event) or b"")


def serve(conn):
    h = h11.Connection(h11.SERVER)
    req, body = None, bytearray()
    try:
        while True:
            try:
                event = h.next_event()
            except h11.RemoteProtocolError as e:
                msg = str(e).encode()[:200]
                try:
                    answer(conn, h, h11.Response(status_code=e.error_status_hint, headers=[
                        ("content-length", str(len(msg))), ("connection", "close")]),
                        h11.Data(data=msg), h11.EndOfMessage())
                except Exception:
                    conn.sendall(b"HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n"
                                 b"connection: close\r\n\r\n")
                return
            if event is h11.NEED_DATA:
                h.receive_data(conn.recv(65536))
            elif isinstance(event, h11.Request):
                req, body = event, bytearray()
            elif isinstance(event, h11.Data):
                body += event.data
            elif isinstance(event, h11.EndOfMessage):
                out = json.dumps({
                    "method": hx(req.method),
                    "target": hx(req.target),
                    "request_uri": hx(req.target),
                    "protocol": hx(b"HTTP/" + req.http_version),
                    "headers": [[hx(n), hx(v)] for n, v in req.headers.raw_items()],
                    "body_len": len(body),
                    "body": hx(body[:512]),
                }).encode()
                answer(conn, h, h11.Response(status_code=200, headers=[
                    ("content-type", "application/json"), ("content-length", str(len(out)))]),
                    h11.Data(data=out), h11.EndOfMessage())
                if h.our_state is h11.MUST_CLOSE:
                    return
                h.start_next_cycle()
            else:  # ConnectionClosed, PAUSED
                return
    except Exception:
        return
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(sys.argv[1])))
    s.listen(64)
    print("h11 echo ready, h11 %s" % h11.__version__, flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
