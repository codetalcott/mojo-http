"""Routes for the example. Each one pins down a specific part of the bridge."""

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


urlpatterns = [
    path("", hello),
    path("cookies", cookies),
    path("echo", echo),
    path("binary", binary),
    path("query", query),
    path("boom", boom),
]
