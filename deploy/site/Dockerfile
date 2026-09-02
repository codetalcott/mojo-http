# The documentation site's image: the m0serve wheel, the built site, and the
# fallback application, in the same python:3.12-slim the PID 1 gate (M11)
# runs on every pull request. Nothing is compiled here.
#
# Build context is the REPOSITORY ROOT (see .dockerignore for what enters),
# and the site must already be built into dist/site for the public URL:
#
#     python3 scripts/docsite.py --out dist/site --base-url https://m0serve.dev
#     docker build -f deploy/site/Dockerfile --build-arg M0SERVE_VERSION=0.17.0 .
#
# Two build arguments choose where the server comes from. M0SERVE_VERSION pins
# the PyPI release (empty installs the newest, which a deploy should never
# rely on; the deploy workflow always pins the tag it was triggered by).
# PIP_INDEX="--no-index" makes pip resolve from /wheelhouse alone, which is
# how poe smoke-site-image tests THIS Dockerfile against the tree's own
# wheel in CI, so the image is proven with the server main actually has
# rather than the one PyPI had last.
FROM python:3.12-slim

ARG M0SERVE_VERSION=
ARG PIP_INDEX=

# The wheelhouse is a directory in the repository holding only .gitkeep; a
# caller stages a wheel into it to install from the tree instead of PyPI.
COPY deploy/site/wheelhouse/ /wheelhouse/
RUN pip install --no-cache-dir --disable-pip-version-check $PIP_INDEX \
      --find-links /wheelhouse "m0serve${M0SERVE_VERSION:+==$M0SERVE_VERSION}" \
    && m0serve --version

# Unprivileged, read-only tree: the site is files the server sendfiles, and
# the application behind the mount writes nothing.
RUN useradd --system --create-home --uid 10001 site
WORKDIR /app
COPY --chown=root:root apps/site/siteapp/ /app/siteapp/
COPY --chown=root:root dist/site/ /app/site/
USER site

ENV M0_SITE_DIST=/app/site \
    M0_SSE_HEARTBEAT_MS=25000 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8080

# m0serve is PID 1 on purpose: it reaps and drains on SIGTERM (M11), so
# `docker stop` and a Fly machine stop are the graceful drain, not a kill.
# Two workers on one shared CPU: the site is sendfile from the loop, and a
# second worker is what keeps a stuck one from being the whole site.
CMD ["m0serve", "siteapp.wsgi:application", "--app-dir", "/app", \
     "--static", "/=/app/site", "--static-cache-control", "public, max-age=300", \
     "--host", "0.0.0.0", "--port", "8080", "--workers", "2", \
     "--health-path", "/health", "--access-log"]
