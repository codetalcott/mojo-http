"""The entry point that imports cleanly, and must not be served in asgi.py's place."""


def application(environ, start_response):
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"split_fail.wsgi served, though split_fail.asgi raised on import\n"]
