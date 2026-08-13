# Provenance

This repository was extracted on 2026-08-12 from the private monorepo
`codetalcott/mojo-framework`, at commit `c935f88e790849959f7a5af2d98407bb30d5efde` (tagged there as
`pre-split-2026-08-12`), using `git filter-repo` over these paths:

    packages/m0-core/  packages/m0-http/  packages/m0-datastar/
    apps/hello/  LICENSE  NOTICE  .python-version

Commit hashes therefore differ from the source repo.

History is **complete** for the paths above — including all 15 commits to
`packages/m0-http/lightbug_http` that [NOTICE](NOTICE) refers to. But most of
the commits carried over originally also touched files that stayed private
(`m0-data`, `m0-hypermedia`, `apps/demo_*`, `agent/`, `RFC.md`), so their
messages may describe work that is not visible here. A message mentioning
GRAIL, Siren, or a task board is one of those.

The 28 `lightbug_http` fork commits predating 2026-03-18 live in a third
private repository, `mojo-siren-grail`, and were not carried into either repo.
NOTICE enumerates what they changed.

`pyproject.toml` and `uv.lock` were **not** carried over. The monorepo's
`pyproject.toml` declares an `mcp` dependency used only by its private GRAIL
agent, which would have invalidated a copied lockfile; both were rewritten here
and the lock regenerated against the same pinned Mojo version.

The vendored `modular/skills` content in the source repo was deliberately
excluded pending confirmation of its license.
