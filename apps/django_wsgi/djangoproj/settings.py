"""Minimal Django settings for the mojo-http WSGI example.

Deliberately small: no database, no admin, no static files. The point is to
prove that a real Django request/response cycle survives the trip through
Mojo, not to demonstrate Django.
"""

SECRET_KEY = "not-a-secret-this-is-an-example"
DEBUG = False
ALLOWED_HOSTS = ["*"]

ROOT_URLCONF = "djangoproj.urls"
WSGI_APPLICATION = "djangoproj.wsgi.application"

INSTALLED_APPS = []
MIDDLEWARE = []

USE_TZ = True
DEFAULT_CHARSET = "utf-8"

# The server terminates plain HTTP; a TLS-terminating proxy should forward the
# scheme in this header. m0-wsgi always reports wsgi.url_scheme as "http".
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
