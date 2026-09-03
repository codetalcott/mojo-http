# The live demo's image (https://demo.m0serve.dev): the m0serve wheel, Django,
# and the one-file demo application, in the same python:3.12-slim the PID 1
# gate (M11) and the docs site's image (F14) run on. Nothing is compiled here.
#
# Build context is the REPOSITORY ROOT (see .dockerignore for what enters):
#
#     docker build -f deploy/demo/Dockerfile --build-arg M0SERVE_VERSION=0.17.0 .
#
# M0SERVE_VERSION pins the PyPI release (empty installs the newest, which a
# deploy should never rely on; the deploy workflow always pins the tag it was
# triggered by). PIP_INDEX="--no-index" makes the m0serve install resolve
# from /wheelhouse alone, which is how `poe smoke-demo` proves THIS
# Dockerfile against the tree's own wheel in CI. Django is installed from
# PyPI in a step of its own so that flag cannot starve it.
FROM python:3.12-slim

ARG M0SERVE_VERSION=
ARG PIP_INDEX=

# The framework first, always from the index: the demo is a Django file, and
# a compatible-release pin lets security releases ride the next deploy.
RUN pip install --no-cache-dir --disable-pip-version-check "django~=6.0"

# The wheelhouse is a directory in the repository holding only .gitkeep; a
# caller stages a wheel into it to install from the tree instead of PyPI.
COPY deploy/demo/wheelhouse/ /wheelhouse/
RUN pip install --no-cache-dir --disable-pip-version-check $PIP_INDEX \
      --find-links /wheelhouse "m0serve${M0SERVE_VERSION:+==$M0SERVE_VERSION}" \
    && m0serve --version

# Unprivileged, read-only tree: the application stores nothing, on purpose.
RUN useradd --system --create-home --uid 10001 demo
WORKDIR /app
COPY --chown=root:root apps/demo/demoapp.py /app/demoapp.py
USER demo

# Fly's proxy closes idle long-lived connections; a comment on every held
# SSE stream and a ping on every WebSocket every 25 s keep them alive.
ENV M0_SSE_HEARTBEAT_MS=25000 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8080

# m0serve is PID 1 on purpose: it reaps and drains on SIGTERM (M11), so
# `docker stop` and a Fly machine stop are the graceful drain, not a kill.
# Two workers, because the claim being demonstrated is "every subscriber on
# every worker": a tab held by one worker hears a message published by the
# other over the bus, and the page says which worker published each line.
# --realtime turns the views' M0-Hold headers into held connections; the
# rest is the abuse posture -- a small body cap (a message is 280 bytes), the
# idle timeout on, the server's own health path for Fly's check, and an
# access log line per response for `fly logs`.
CMD ["m0serve", "demoapp:application", "--app-dir", "/app", "--realtime", \
     "--host", "0.0.0.0", "--port", "8080", "--workers", "2", \
     "--max-body", "8k", "--idle-timeout", "60", \
     "--health-path", "/health", "--access-log"]
