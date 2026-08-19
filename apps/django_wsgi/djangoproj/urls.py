"""Routes for the example. Each one pins down a specific part of the bridge."""

import os
import time

from django.http import HttpResponse
from django.urls import path


def hello(request):
    """The base case: a request reaches a view and its body comes back."""
    return HttpResponse("hello from django on mojo-http", content_type="text/plain")


def cookies(request):
    """Two Set-Cookie headers on one response.

    `Headers` in the server is a Dict[String, String], so a naive mapping keeps
    only the last cookie. This is the regression test for that — Django sets
    exactly this pair (sessionid + csrftoken) on any authenticated response.
    """
    response = HttpResponse("cookies set", content_type="text/plain")
    response.set_cookie("sessionid", "abc123")
    response.set_cookie("csrftoken", "xyz789")
    return response


def echo(request):
    """Proves wsgi.input: the request body must survive the crossing."""
    return HttpResponse(request.body, content_type="application/octet-stream")


def binary(request):
    """Proves the body path is binary-safe.

    Returns all 256 byte values. A latin-1 round trip through a Mojo String
    would corrupt everything above 0x7F, since Mojo strings are UTF-8.
    """
    return HttpResponse(bytes(range(256)), content_type="application/octet-stream")


def query(request):
    """Proves QUERY_STRING is parsed by Django, not swallowed by the server."""
    return HttpResponse(request.GET.get("name", ""), content_type="text/plain")


def cookies_echo(request):
    """Echoes the cookies Django parsed out of the request.

    The regression test for the request half of the cookie path. The server
    used to divert `Cookie` out of the header map into its own jar, so
    `HTTP_COOKIE` never reached the environ and this view saw nothing —
    which is a logged-out visitor as far as any Django app can tell.
    """
    pairs = sorted(f"{k}={v}" for k, v in request.COOKIES.items())
    return HttpResponse("|".join(pairs), content_type="text/plain")


def session_bump(request):
    """Increments a counter held in the session, and reports it.

    The round trip: Django writes `sessionid` as a Set-Cookie on the way out,
    the client sends it back, and the count only advances if the request half
    of the cookie path works. A server that drops request cookies answers 1
    forever, which is why the smoke asserts the sequence and not one call.
    """
    count = request.session.get("count", 0) + 1
    request.session["count"] = count
    return HttpResponse(f"count={count}", content_type="text/plain")


def boom(request):
    """Raises, so the server's 500 path can be asserted."""
    raise RuntimeError("intentional failure")


def wsgi(request):
    """Exposes wsgi.multiprocess, pinning the M0_WORKERS wiring in server.mojo."""
    return HttpResponse(
        f"multiprocess={request.META['wsgi.multiprocess']}", content_type="text/plain"
    )


def slow(request):
    """Holds its worker for a while, and says which worker that was.

    The multi-worker smoke test overlaps two of these: if they finish in ~1x
    the sleep, they ran in parallel. The pid is in the body so the test can
    require the pair to have been answered by two distinct workers — with the
    shared pre-fork listener a busy worker never accepts, so this holds on
    every attempt, but the test still retries rather than trust one race.
    """
    time.sleep(1.5)
    return HttpResponse(f"slow done pid={os.getpid()}", content_type="text/plain")


urlpatterns = [
    path("", hello),
    path("cookies", cookies),
    path("cookies/echo", cookies_echo),
    path("session/bump", session_bump),
    path("echo", echo),
    path("binary", binary),
    path("query", query),
    path("boom", boom),
    path("wsgi", wsgi),
    path("slow", slow),
]
