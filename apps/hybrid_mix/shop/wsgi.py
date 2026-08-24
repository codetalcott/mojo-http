"""WSGI entry point for the mounted Django half."""

import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "shop.settings")

application = get_wsgi_application()
