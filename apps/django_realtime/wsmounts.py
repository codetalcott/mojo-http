"""Two bare WSGI applications, mounted side by side under `--realtime`.

`smoke-django-realtime-ws`'s inline-mounts phase serves them as
`--mount /=wsmounts:first --mount /b=wsmounts:second --blocking-threads 0`:
no pool, so ONE `WSGIHandler` on the loop holds both applications and takes
every hold itself. Each approves a WebSocket at `/ws` and answers the
server's synthetic `/ws/message` POST by publishing, onto the socket's own
channel, a JSON line naming ITSELF and the `SCRIPT_NAME` and `PATH_INFO` it
was called with. So `mounts_ws_probe.py` reads, from the socket, which
mount's view received its message and at which path.

A socket the SECOND mount approved had its messages delivered to the FIRST
until the server recorded, per held socket, the application that approved
it: the synthetic request was built under `mount_prefixes[0]` and served by
`apps[0]`, whichever mount had taken the hold.

Stdlib and `m0pub` only, so the phase runs wherever the repository runs.
"""

import json
from urllib.parse import parse_qs

import m0pub


def _text(start_response, status, body):
    start_response(status, [("Content-Type", "text/plain")])
    return [body]


def _application(name):
    def application(environ, start_response):
        path = environ.get("PATH_INFO", "")
        if path == "/ws":
            query = parse_qs(environ.get("QUERY_STRING", ""))
            channel = query.get("channel", [""])[0]
            if not channel:
                return _text(start_response, "400 Bad Request", b"no channel\n")
            start_response(
                "200 OK",
                [
                    ("Content-Type", "text/plain"),
                    ("M0-Hold", "websocket"),
                    ("M0-Channel", channel),
                ],
            )
            return [b""]
        if path == "/ws/message" and environ.get("REQUEST_METHOD") == "POST":
            channel = environ.get("HTTP_M0_CHANNEL", "")
            size = int(environ.get("CONTENT_LENGTH") or 0)
            text = environ["wsgi.input"].read(size).decode("utf-8", "replace")
            m0pub.publish(
                channel,
                json.dumps(
                    {
                        "app": name,
                        "script_name": environ.get("SCRIPT_NAME", ""),
                        "path_info": path,
                        "text": text,
                    }
                ),
                event="message",
            )
            return _text(start_response, "200 OK", b"delivered\n")
        return _text(start_response, "404 Not Found", b"not found\n")

    return application


first = _application("first")
second = _application("second")
