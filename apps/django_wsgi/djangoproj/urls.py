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
    the sleep, they ran in parallel. The pid is in the body because
    SO_REUSEPORT assigns connections to workers by hash — two requests *can*
    land on the same worker, and the test needs to see that and retry rather
    than misread the serial timing as a concurrency failure.
    """
    time.sleep(1.5)
    return HttpResponse(f"slow done pid={os.getpid()}", content_type="text/plain")


urlpatterns = [
    path("", hello),
    path("cookies", cookies),
    path("echo", echo),
    path("binary", binary),
    path("query", query),
    path("boom", boom),
    path("wsgi", wsgi),
    path("slow", slow),
]
