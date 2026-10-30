"""A WSGI application whose views approve holds, for `smoke-max-connections`.

`/hold` approves an SSE stream and `/ws` a WebSocket, both on channel `c`;
anything else is a plain 200. The gate fills a loop's stream share with
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
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"ok\n"]
