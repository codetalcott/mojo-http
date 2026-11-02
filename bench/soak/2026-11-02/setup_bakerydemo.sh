#!/bin/bash
# bakerydemo for the 1.17.0 re-soak, at c8f8255 (the 2026-10-09 commit; cloned
# by hand first: git clone https://github.com/wagtail/bakerydemo.git
# /tmp/soak/bakerydemo && git -C /tmp/soak/bakerydemo checkout c8f8255).
# Its own .python-version (3.12) picks the interpreter; requirements are
# ranges, so the patch versions are whatever resolves today.
# asgi.py is the file this record added in 2026-09 (bench/soak/2026-09-04/
# bakerydemo-asgi.py): the soak rows serve bakerydemo.wsgi only, so it is
# there to keep the checkout in its recorded shape, not because a row uses it.
set -eu
cd /tmp/soak/bakerydemo
unset DATABASE_URL DJANGO_SETTINGS_MODULE
git log -1 --format='checkout %h %s'
uv venv --python 3.12 .venv 2>&1 | tail -1
uv pip install --python .venv/bin/python -r requirements/development.txt gunicorn 2>&1 | tail -2
.venv/bin/python --version
.venv/bin/python -c 'import django, wagtail, gunicorn; print("django", django.__version__, "wagtail", wagtail.__version__, "gunicorn", gunicorn.__version__)'
cp bakerydemo/settings/local.py.example bakerydemo/settings/local.py
cp .env.example .env
cp /Users/williamtalcott/projects/mojo-http-fdfit/bench/soak/2026-09-04/bakerydemo-asgi.py bakerydemo/asgi.py
.venv/bin/python manage.py migrate --noinput 2>&1 | tail -2
.venv/bin/python manage.py load_initial_data 2>&1 | tail -3
.venv/bin/python manage.py shell -c '
from django.contrib.auth import get_user_model
u = get_user_model().objects.get(username="admin")
print("admin user", u.pk, "password changeme:", u.check_password("changeme"))
'
