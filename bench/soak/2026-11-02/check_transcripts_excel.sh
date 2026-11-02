#!/bin/bash
# The status-only excel route must answer 200 (the soak checks only that).
cd /tmp/soak/transcripts
.venv/bin/python manage.py shell -c '
from django.test import Client
r = Client(HTTP_HOST="127.0.0.1").get("/student/1/excel/")
print("excel", r.status_code, r.get("Content-Type"), len(r.content))
'
