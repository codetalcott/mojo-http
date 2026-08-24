"""Minimal Django settings for the mounted-applications example.

Same charter as `apps/django_wsgi`: no database, no admin, nothing to
demonstrate but that a real Django request/response cycle survives being
mounted under a prefix.
"""

SECRET_KEY = "not-a-secret-this-is-an-example"
DEBUG = False
ALLOWED_HOSTS = ["*"]

ROOT_URLCONF = "shop.urls"
WSGI_APPLICATION = "shop.wsgi.application"

INSTALLED_APPS = []
MIDDLEWARE = []

USE_TZ = True
DEFAULT_CHARSET = "utf-8"
