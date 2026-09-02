# site

The documentation site: the repository's own pages -- README, QUICKSTART,
CHANGELOG, PROVENANCE and everything under `docs/` -- rendered to HTML by
[scripts/docsite.py](../../scripts/docsite.py) and served by `m0serve` through
`--static`, with `llms.txt`, `llms-full.txt`, `sitemap.xml`, `robots.txt` and
`spec.json` at the root and a Markdown twin beside every page.

`siteapp` is the application behind the mount. It answers only what the
static tree does not: a directory named without its slash gets a permanent
redirect to the slashed form, and everything else gets the site's own
`404.html`. There is no other dynamic behaviour, on purpose -- every page is
a file the server sends without Python in the path.

```bash
uv run poe build-site          # render into dist/site for http://localhost:8180
uv run poe serve-site          # build, then serve it on :8180
uv run poe smoke-site          # what CI runs: every sitemap URL answers, the
                               # root text files carry absolute URLs, the
                               # redirect and the 404 page

# A deployable build names its public URL; canonical links, the sitemap and
# llms.txt are absolute.
python3 scripts/docsite.py --out dist/site --base-url https://your.domain
M0_SITE_DIST=dist/site bin/m0serve siteapp.wsgi:application \
  --app-dir apps/site --static /=$PWD/dist/site --port 8180
```

`python3 scripts/docsite.py --check` is the link check on its own (standard
library only, so `scripts/check_docs.py` runs it on doc-only pull requests):
every relative link in the corpus resolves to a page, an asset or a file in
the repository, every `#fragment` names a heading that exists, and every
`docs/*.md` is listed with a title and a description. `--selftest` proves
each of those checks can fail.
