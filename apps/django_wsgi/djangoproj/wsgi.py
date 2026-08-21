"""WSGI entry point. `WSGIApp` imports this module and takes `application`.

Setting `M0_WSGI_VALIDATE` wraps the application in `wsgiref.validate`, the
stdlib's own PEP 3333 checker. It is the closest thing to a conformance suite
for a WSGI *server*: it asserts that every environ key the server is required
to supply is present and correctly typed, that `Content-Type`/`Content-Length`
arrive without the `HTTP_` prefix while every other header keeps it, that
`wsgi.input` and `wsgi.errors` implement the required methods, and that the
application's return value is closed exactly once.

A violation raises `AssertionError` out of the application call. `m0-wsgi`
propagates whatever the application raised, and the event loop answers 500 —
so a conformance failure surfaces as a 500, never as a quiet pass.

Off by default: the wrapper copies the environ and wraps `wsgi.input` on every
request, which is not a cost production should carry. `poe smoke-django` runs
a dedicated pass with it on, and asserts the `/pep3333/canary` route to prove
the wrapper is actually engaged rather than skipped by a misspelled variable.
"""

import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "djangoproj.settings")

application = get_wsgi_application()

if os.environ.get("M0_WSGI_VALIDATE"):
    from wsgiref.validate import validator

    application = validator(application)
