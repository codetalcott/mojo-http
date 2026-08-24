"""Routes that prove a mounted Django app sees its own prefix.

The interesting one is `/where`. Django builds absolute URLs from
SCRIPT_NAME, so `reverse()` and `request.build_absolute_uri()` are the two
values that go wrong -- silently, and only in links -- if the server hands
the application a prefix it does not actually strip from PATH_INFO. Both are
in the response, and `poe smoke-hybrid` compares them byte for byte.
"""

import json

from django.http import HttpResponse
from django.urls import path, reverse


def hello(request):
    return HttpResponse("hello from django on mojo-http", content_type="text/plain")


def where(request):
    """Everything the mount contract decides, in one JSON body."""
    return HttpResponse(
        json.dumps(
            {
                "script_name": request.META.get("SCRIPT_NAME", ""),
                "path_info": request.META.get("PATH_INFO", ""),
                # Django's own view of the request: `path` includes the
                # prefix, `path_info` does not. An app that generates links
                # uses the first.
                "request_path": request.path,
                "request_path_info": request.path_info,
                "reverse_where": reverse("where"),
                "absolute_uri": request.build_absolute_uri(),
            }
        ),
        content_type="application/json",
    )


urlpatterns = [
    path("", hello),
    path("where", where, name="where"),
]
