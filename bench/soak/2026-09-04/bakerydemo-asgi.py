"""
ASGI config for bakerydemo.

NOT part of the upstream repo: bakerydemo ships only wsgi.py. This is the
file `django-admin startproject` generates, with the two lines wsgi.py adds
(dotenv, and the dev settings default) so the two entry points agree.
"""

import os

import dotenv
from django.core.asgi import get_asgi_application

dotenv.load_dotenv()

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "bakerydemo.settings.dev")

application = get_asgi_application()
