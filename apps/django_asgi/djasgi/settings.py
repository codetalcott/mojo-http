"""Minimal Django settings for the ASGI example.

Same charter as `apps/django_wsgi`: no database, no admin, nothing to
demonstrate but that a real Django ASGI request/response cycle survives the
trip — this time through the asyncio executor rather than the WSGI pool.

Sessions ride the signed-cookie backend so the "no database" rule holds;
they are here for the same reason as on the WSGI row: a session counter is
the round trip that proves cookies survive in BOTH directions.
"""

SECRET_KEY = "not-a-secret-this-is-an-example"
DEBUG = False
ALLOWED_HOSTS = ["*"]

ROOT_URLCONF = "djasgi.urls"
ASGI_APPLICATION = "djasgi.asgi.application"

INSTALLED_APPS = ["django.contrib.sessions"]
MIDDLEWARE = ["django.contrib.sessions.middleware.SessionMiddleware"]
SESSION_ENGINE = "django.contrib.sessions.backends.signed_cookies"

USE_TZ = True
DEFAULT_CHARSET = "utf-8"
