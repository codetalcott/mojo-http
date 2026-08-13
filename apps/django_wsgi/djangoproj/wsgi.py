"""WSGI entry point. `WSGIApp` imports this module and takes `application`."""

import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "djangoproj.settings")

application = get_wsgi_application()
