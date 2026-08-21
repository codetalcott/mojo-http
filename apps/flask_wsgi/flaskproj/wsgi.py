"""A Flask row for the WSGI framework contract.

Second framework, same server, no changes to `m0-wsgi` to make it work — which
is the whole claim this app exists to support. It implements exactly the route
contract in `scripts/wsgi_framework_contract.sh` and nothing else; anything
Flask-specific belongs in its own assertions, not in the shared contract.

Compare `apps/django_wsgi/djangoproj/urls.py`: same routes, same semantics,
same expected bytes, two entirely different frameworks. The pair is the
evidence that the host is framework-agnostic, where one framework could only
ever be an anecdote.

Flask is a dev dependency, and `poe smoke-flask` skips cleanly when it is not
installed.
"""

from flask import Flask, Response, request

app = Flask(__name__)


@app.get("/")
def root():
    return Response("hello from flask on mojo-http", mimetype="text/plain")


@app.get("/cookies")
def cookies():
    """Two Set-Cookie headers on one response.

    `Headers` on the Mojo side is a Dict[String, String], so a naive mapping
    keeps only the last one. Django's pair is sessionid + csrftoken; Flask's
    is the same pair by convention, which is what makes the contract shared.
    """
    response = Response("cookies set", mimetype="text/plain")
    response.set_cookie("sessionid", "abc123")
    response.set_cookie("csrftoken", "xyz789")
    return response


@app.get("/cookies/echo")
def cookies_echo():
    """Whatever cookies Werkzeug parsed out of the request.

    The regression test for the request half: the server used to divert
    `Cookie` out of the header map, so HTTP_COOKIE never reached the environ
    and this returned empty for every request.
    """
    pairs = sorted(f"{k}={v}" for k, v in request.cookies.items())
    return Response("|".join(pairs), mimetype="text/plain")


@app.post("/echo")
def echo():
    """Proves wsgi.input: the request body must survive the crossing."""
    return Response(request.get_data(), mimetype="application/octet-stream")


@app.get("/binary")
def binary():
    """All 256 byte values. A latin-1 round trip through a Mojo String would
    corrupt everything above 0x7F, since Mojo strings are UTF-8."""
    return Response(bytes(range(256)), mimetype="application/octet-stream")


@app.get("/query")
def query():
    """QUERY_STRING reaching Flask's own parameter parsing."""
    return Response(request.args.get("name", ""), mimetype="text/plain")


@app.get("/boom")
def boom():
    """Raises, so the 500 path is reachable.

    Flask catches this itself and renders its own 500 rather than letting it
    reach the server, which is a difference from the Django row worth knowing:
    the contract asserts the status the client sees, not which layer produced
    it, because that is the part a framework is entitled to decide.
    """
    raise RuntimeError("intentional failure")


application = app
