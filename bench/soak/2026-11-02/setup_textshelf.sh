#!/bin/bash
# textshelf for the 1.17.0 re-soak, at 7ada52ed (cloned by hand first:
# git clone ~/projects/textshelf /tmp/soak/textshelf).
#
# Environment: .envs/.local/.django no longer exists (deleted in d81940fa1,
# 2026-09-09, before the 2026-10-09 pass), and the clone has no root .env, so
# -- exactly as bench/soak/2026-10-09/baseline_ts.sh and soak_rows.sh did --
# only DATABASE_URL (the SCRATCH database, no password: libpq reads
# ~/.pgpass) and DJANGO_SETTINGS_MODULE are exported. NEVER the database
# named `textshelf`: that is the developer's data. Every manage.py step below
# runs after a guard that refuses any other database name.
#
# venv: its uv.lock with the dev group (local settings load debug_toolbar,
# django_extensions, django_watchfiles; psycopg is in dev), CPython 3.13.6
# (the 2026-10-09 interpreter), daphne added, and the lock's m0serve 1.14.0
# replaced by the newest wheel in mojo-http-ready/dist/wheels/ (the app
# imports m0serve.m0pub at startup).
set -eu
export DATABASE_URL="postgres://postgres@localhost:5432/textshelf_soak"
export DJANGO_SETTINGS_MODULE=config.settings.local
WHEEL=/Users/williamtalcott/projects/mojo-http-ready/dist/wheels/m0serve-1.16.0-py3-none-macosx_13_0_arm64.whl
cd /tmp/soak/textshelf
git log -1 --format='checkout %h %s'
uv sync --python 3.13.6 2>&1 | tail -2
uv pip install --python .venv/bin/python daphne 2>&1 | tail -2
uv pip install --python .venv/bin/python "$WHEEL" 2>&1 | tail -3
.venv/bin/python --version
.venv/bin/python -c 'import django, daphne, m0serve.m0pub, importlib.metadata as md; print("django", django.__version__, "daphne", daphne.__version__, "m0serve", md.version("m0serve"))'

guard() {
  .venv/bin/python -c '
import django; django.setup()
from django.db import connection
name = connection.settings_dict["NAME"]
assert name == "textshelf_soak", "REFUSING: settings name database %r" % name
print("database guard ok:", name, connection.settings_dict.get("HOST"), connection.settings_dict.get("PORT"))
'
}
guard
echo "unapplied migrations: $(.venv/bin/python manage.py showmigrations --plan | grep -c '\[ \]' || true)"
guard
.venv/bin/python manage.py migrate --noinput 2>&1 | tail -3
guard
.venv/bin/python manage.py shell -c '
from django.db import connection
assert connection.settings_dict["NAME"] == "textshelf_soak"
from django.contrib.auth import get_user_model
from allauth.account.models import EmailAddress
U = get_user_model()
u = U.objects.get(email="soak@example.com")
print("soak user pk", u.pk, "active", u.is_active, "password ok", u.check_password("soak-pass-123"))
print("email addresses", list(EmailAddress.objects.filter(user=u).values_list("email", "verified", "primary")))
print("users in textshelf_soak:", U.objects.count())
'
