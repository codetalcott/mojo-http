#!/bin/bash
# transcripts for the 1.17.0 re-soak: clone at 00dcb7a (done by hand first:
#   git clone ~/projects/transcripts /tmp/soak/transcripts),
# a venv from its own uv.lock on CPython 3.13.6 (the 2026-10-09 interpreter),
# gunicorn INSIDE the venv (2026-10-09: a fresh venv lacked it and the system
# one would have served the capture), migrate, then the dev user and ONE
# Student row (id 1) through the ORM, because `init_data --with-samples`
# fails on students.owner_id NOT NULL.
set -eu
cd /tmp/soak/transcripts
git log -1 --format='checkout %h %s'
uv sync --python 3.13.6 2>&1 | tail -3
uv pip install --python .venv/bin/python gunicorn==26.2.0 2>&1 | tail -2
.venv/bin/python --version
.venv/bin/python -c 'import django, gunicorn; print("django", django.__version__, "gunicorn", gunicorn.__version__)'
.venv/bin/python manage.py migrate --noinput 2>&1 | tail -2
.venv/bin/python manage.py shell -c '
import datetime
from transcript_manager.models import User, Student
u, _ = User.objects.get_or_create(email="admin@transcripts.local",
    defaults=dict(username="admin", is_staff=True, is_superuser=True))
if not u.has_usable_password():
    u.set_password("devpassword"); u.save()
s, made = Student.objects.get_or_create(pk=1, defaults=dict(
    owner=u, first_name="Soak", last_name="Student",
    date_of_birth=datetime.date(2010, 3, 14),
    address_line1="1 Test Street", city="Baltimore", state="MD",
    zip_code="21201", parent1_name="Soak Parent"))
print("user", u.pk, u.email, "student", s.pk, s.get_full_name(), "created" if made else "existed")
'
