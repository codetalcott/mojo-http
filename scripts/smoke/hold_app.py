"""A WSGI application whose views approve holds, for `smoke-max-connections`.

`/hold` approves an SSE stream and `/ws` a WebSocket, both on channel `c`;
`/publish` sends one event to channel `c`: `data: drained`, or `data: end`
for `?end=1`, or a `data:` line of N bytes for `?fill=N`; anything else is
a plain 200. The gate fills a loop's stream share with
`/hold` and asks what the next stream, the health path and an ordinary
request are answered.
"""


def application(environ, start_response):
    path = environ.get("PATH_INFO", "")
    if path == "/hold":
        start_response("200 OK", [
            ("Content-Type", "text/event-stream"),
            ("M0-Hold", "stream"),
            ("M0-Channel", "c"),
        ])
        return [b": held\n\n"]
    if path == "/ws":
        start_response("200 OK", [
            ("Content-Type", "text/plain"),
            ("M0-Hold", "websocket"),
            ("M0-Channel", "c"),
        ])
        return [b""]
    if path == "/publish":
        # The smoke puts `m0serve/m0pub.py` on PYTHONPATH, as the wheel
        # does; a frame, so nothing needs numbering it.
        from m0serve import m0pub

        query = environ.get("QUERY_STRING", "")
        frame = b"data: drained\n\n"
        if query == "end=1":
            frame = b"data: end\n\n"
        elif query.startswith("fill="):
            frame = b"data: " + b"x" * int(query[5:]) + b"\n\n"
        reached = m0pub.publish_frame("c", frame)
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [b"published to %d\n" % reached]
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"ok\n"]
