"""Minimal Django settings for the realtime example.

Even smaller than `apps/django_wsgi`'s: no contrib apps, no middleware, no
database. The point is the hold-and-publish path, and the only Django
machinery it needs is URL routing and plain responses. Auth is a query-string
token checked in the view — deliberately primitive, because what it
demonstrates is *where* the subscription decision lives (in Django), not how
production auth should look.
"""

SECRET_KEY = "not-a-secret-this-is-an-example"
DEBUG = False
ALLOWED_HOSTS = ["*"]

ROOT_URLCONF = "djangoproj.urls"
WSGI_APPLICATION = "djangoproj.wsgi.application"

USE_TZ = True
DEFAULT_CHARSET = "utf-8"
