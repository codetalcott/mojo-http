"""Minimal Django settings for the mojo-http WSGI example.

Deliberately small: no database, no admin, no static files. The point is to
prove that a real Django request/response cycle survives the trip through
Mojo, not to demonstrate Django.

Sessions are the one contrib app enabled, on the signed-cookie backend so the
"no database" rule above still holds. They earn their place: a session is the
round trip that proves cookies survive in *both* directions, and it is exactly
what stayed broken while the server dropped the request's `Cookie` header —
silently, because a request that never carries a session back just looks like
a logged-out visitor.
"""

SECRET_KEY = "not-a-secret-this-is-an-example"
DEBUG = False
ALLOWED_HOSTS = ["*"]

ROOT_URLCONF = "djangoproj.urls"
WSGI_APPLICATION = "djangoproj.wsgi.application"

INSTALLED_APPS = ["django.contrib.sessions"]
MIDDLEWARE = ["django.contrib.sessions.middleware.SessionMiddleware"]
SESSION_ENGINE = "django.contrib.sessions.backends.signed_cookies"

USE_TZ = True
DEFAULT_CHARSET = "utf-8"

# The server terminates plain HTTP; a TLS-terminating proxy should forward the
# scheme in this header. m0-wsgi always reports wsgi.url_scheme as "http".
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
