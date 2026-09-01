# Releasing

Releases are tag-driven: pushing a `v*` tag runs the `Release` workflow
(`.github/workflows/release.yml`), which builds `libm0core` on Linux and
macOS, proves each artifact through the same `ctypes` smoke that CI runs on
every commit, and publishes a GitHub release with both attached.

**Before any of it: `uv run poe stress-asgi`.** The one check CI cannot
run. Each round drives `chunked_keepalive.py` and then
`apps/asgi_bare/ws_probe.py` under CPU hogs — thirty rounds per loop
mode, once on the pump and once under `M0_INVERTED=1`. That order is the
shape that finds a slot-ownership race in the ASGI executor: the probe's
HTTP/1.0 request closes after its head, so what follows lands on the
connection slot it just released, and the hogs are what make the previous
task's cancellation and done-callback land late enough to collide with
its successor. Measured on the broken build it failed on round 5 of 15;
on shared CI runners it did not fail at all for a whole day with the bug
live, which is why this is a step here rather than a job there. The
WebSocket half is there because a CI flake landed in the one combination
nothing gated — the WS path, the inversion and contention together
(ROADMAP, "The WebSocket path is not stressed", now under Recently
resolved); reverting the `websocket.send` credit gate is caught on round 1
and was not caught at all by the streamed rounds alone. The deterministic half of the same
guard, `poe test-shim`, runs in CI inside `test-all`. Tune with
`M0_STRESS_ITERS` and `M0_STRESS_HOGS`, and narrow a rerun to the mode a
failure named with `M0_STRESS_MODES=inverted`; it must be N of N in both
modes.

**And `uv run poe probe-pool`**, the Mojo handler pool's timing half —
pre-release for the same reason stress-asgi is: a p99 table from a shared
runner is noise. The pooled row must hold single-digit milliseconds at
`slow=1` and `slow=2` (measured 0.2–0.3 ms on an M4; the loop-only row
collapsing to ~the blocking duration is expected and is the point), and
the final column is the deliberate saturation boundary — more blockers
than threads — where the pooled row is EXPECTED to collapse too. The
deterministic halves, `test_mojo_pool` and `poe sabotage-pool`, run in CI.

**`uv run poe autobahn`** — Autobahn|Testsuite against the pinned baseline
(SPEC I13). Pre-release because it needs Docker and ~ten minutes, and its
unique value — close-code validation, I16 — is a defect fixed once rather
than a regression that recurs (ROADMAP, "A conformance-suite tier"). The
runner drives the sections separately (a single pass wedges on the slot a
cap-killed connection just released), skips 9 (performance: every case
exceeds the cap) and 12/13 (`permessage-deflate`, I14), and compares in
both directions: any failure outside I17's seven cap cases
(1.1.6–1.1.8, 1.2.6–1.2.8, 10.1.1) is new and fails the run, and one of
those seven *passing* fails it too — the cap moved and SPEC I17 is wrong;
do not absorb that silently. The comparator's `--selftest` runs first, so
a green run cannot mean the parser checks nothing.

**`uv run poe fuzz-request-long`** — the deep fuzz sweep, eight seeds x
250k iterations (G13's release depth; CI runs the short form every PR).

**And `uv run poe sabotage-outbox-cap`** — reverts each outbox-cap rule
and insists the I17 probe fails; pre-release because its harness rebuilds
`bin/m0serve` per sabotage, which is minutes of compile CI does not spend.

The steps, in order:

1. **Update [CHANGELOG.md](../CHANGELOG.md).** Add a `## [X.Y.Z] — date`
   section at the top and a link reference at the bottom. The release notes
   point here, so this is the document of record.
2. **Bump `version` in `pyproject.toml`** to match, and `M0SERVE_VERSION`
   in `packages/m0-wsgi/src/cli.mojo` — `smoke-serve` asserts the two agree,
   so CI catches a bump that forgot one. (Locally, rebuild the package
   before the binary — `poe build-wsgi` then `poe build-serve` — because
   `M0SERVE_VERSION` is compiled into the m0-wsgi `.mojoc`, and
   `build-serve` alone links whatever version that artifact already holds;
   a `bin/m0serve --version` that still prints the old number after a bump
   is that, not a bump that missed.) Then run `uv lock` so `uv.lock`'s
   own project version follows (a bare `uv run` later will rewrite it
   otherwise), and update the `m0serve X.Y.Z` echo in
   [QUICKSTART.md](../QUICKSTART.md) — it is the output of a command the
   quickstart promises is executed, but it sits in a ```text block, which
   `run_quickstart.py` displays rather than asserts. `poe check-docs` fails
   on all four, so none of this is remembered by hand.
3. **Land those changes on `main`** through an ordinary PR — CI green first,
   like any change.
4. **Tag and release**, either way:
   - Push a tag (needs tag-push rights):

     ```bash
     git tag vX.Y.Z <merge-commit>
     git push origin vX.Y.Z
     ```

   - Or dispatch the `Release` workflow (Actions → Release → Run workflow)
     with `tag` and `sha` inputs — it creates the tag *and* the release in
     one run.
   - Or push a `release/vX.Y.Z` branch at the commit to release — same
     one-run behavior, with the tag named by the branch. This is the path
     for automation whose credentials can push branches but not tags, and
     whose workflow dispatches run with a capped GITHUB_TOKEN (an
     integration-dispatched run cannot create releases; a push-triggered
     run can). Delete the branch afterwards — `poe check-docs` fails on a
     `release/v*` branch whose tag exists, so this is not remembered by
     hand either. It went unremembered four times before that check
     existed.

5. **The C-ABI bundle is gated, not checked by hand.** CI runs
   `poe bundle-ffi` on every commit and the release workflow runs it again,
   and it refuses to finish unless the bundle is genuinely self-contained —
   so a release cannot ship a `libm0core` that only loads on the runner,
   which is what every release through v0.7.0 did. Nothing to do here;
   `poe bundle-ffi` locally if you want to see what ships.
   [FFI_DISTRIBUTION.md](FFI_DISTRIBUTION.md) has the history and the
   licensing position.

6. The workflow does the rest. If a build or the artifact proof fails, no
   release is created — fix, delete the tag if it was pushed
   (`git push origin :vX.Y.Z`), and re-run.

Versioning is SemVer with the standard pre-1.0 caveat, stated in the
README: minor versions may break the API. The version lives in
`pyproject.toml`, the changelog, and `M0SERVE_VERSION` — the one constant
a package carries, because `m0serve --version` has to answer something.
Nothing else may add one: `smoke-serve` cross-checks exactly that pair, so
a fourth copy would drift silently.

## The PyPI wheel

`m0serve` is published to PyPI as a platform wheel. The distribution name is
`m0serve`, not `mojo-http`: it matches the command users type, it keeps
distance from Modular's `mojo` mark, and it names what is actually in the
archive — the server binary, not the Mojo packages. The GitHub repository
keeps its own name; a repository and a distribution need not agree.

```bash
uv run poe build-wheel     # stage, measure the tag, build into dist/wheels/
uv run poe smoke-wheel     # + install it outside the tree and serve from it
```

Four properties of this that are easy to get wrong later:

- **The version is derived, never bumped.** `packaging/m0serve/pyproject.toml`
  declares `dynamic = ["version"]` and `hatch_version.py` reads the root
  `pyproject.toml`, cross-checking `M0SERVE_VERSION` and *refusing to build*
  on drift. The two copies this document already names stay the only two;
  `check-docs` fails if a third appears.

- **The platform tag is measured, not declared.** `scripts/wheel_tag.py`
  reads `LC_BUILD_VERSION` and versioned glibc symbols out of the staged
  binaries and takes the strictest floor across all of them. Copying the
  toolchain's own tag would have shipped a `macosx_13_0` wheel containing a
  binary that requires macOS 26.

- **There is no ABI tag, on purpose.** `m0serve` does not link libpython, so
  one wheel per platform serves CPython 3.10–3.14 including free-threaded
  builds. If a future change ever puts libpython on the link line, this stops
  being true and the wheel needs a tag per interpreter — a much larger matrix.

- **A PyPI filename is burned permanently.** It cannot be re-uploaded after a
  delete, and a yank (PEP 592) leaves the file installable by exact pin. So
  rehearse on TestPyPI first with an `rc`, upload the *identical* files to
  PyPI without rebuilding, and treat rc numbers as the cheap resource.

### The first upload, concretely

One-time, and only you can do these — they need accounts this repository
cannot reach:

1. PyPI → *Your projects* → **Publishing** → add a **pending** publisher:
   project `m0serve`, owner `codetalcott`, repository `mojo-http`, workflow
   `release.yml`, environment `pypi`. Repeat on TestPyPI.
2. This repository → Settings → Environments → `pypi`. It exists and is
   configured; what it enforces is below.
3. Settings → Secrets and variables → Actions → Variables → set
   `PUBLISH_TO_PYPI` to `true`. Until then `publish-pypi` is skipped, so a
   tag pushed today produces a GitHub release and no upload.

**The environment is the authorization boundary, not `PUBLISH_TO_PYPI`.**
Trusted publishing trusts the tuple (owner, repository, workflow,
environment), so anything that can make `release.yml` reach the `pypi`
environment can upload under your name. The `PUBLISH_TO_PYPI` variable and
`publish-pypi`'s wheel-set validation both live inside the repository and are
editable by anyone with write access; the environment's rules are not. Two
gates enforce it:

- **A deployment branch policy** admitting only `release/v*` branches and
  `v*` tags. Those are already the only refs whose runs can pass
  `publish-pypi`'s version check, which derives the expected version from
  `GITHUB_REF_NAME` — so this refuses nothing that used to work. It stops a
  run from any other ref reaching the upload step at all.
- **A required reviewer.** Every release now *pauses* at `publish-pypi` and
  waits for an approval on the run's page. That is not a stuck workflow: it
  is the last moment at which a permanently-burned filename can be called
  off. Approve it and the upload proceeds.

Then rehearse before anything is burned:

```bash
# 1. Bump BOTH copies to the release candidate, and let the ratchet check you.
#    (pyproject.toml `version`, cli.mojo M0SERVE_VERSION -- see above.)
uv run poe check-docs

# 2. Build and prove it locally.
uv run poe smoke-wheel

# 3. Collect the OTHER platform's wheel from a CI run rather than rebuilding
#    it -- the wheels you upload must be the wheels that were tested.
gh run download <run-id> --pattern 'wheel-*' --dir dist/wheels

# 4. TestPyPI. Filenames there are worthless, so burn rc numbers freely.
uvx twine check --strict dist/wheels/*.whl
uvx twine upload --repository testpypi dist/wheels/*.whl

# 5. The assertion that matters: pip must pick the right file out of several
#    platform wheels, from an index, on a machine that never built them.
docker run --rm python:3.12-slim-bookworm sh -c \
  'pip install -i https://test.pypi.org/simple/ m0serve && m0serve --version'
```

Only then tag for real. Upload the **identical files**, verified by sha256 —
rebuilding between the rehearsal and the release means you tested a different
artifact.

**What an rc does and does not buy.** It rehearses the whole upload path on
a filename you can afford to burn. It does **not** hide the package: pip
excludes pre-releases only when a stable version also exists, so while `rcN`
is the only version on the index, `pip install m0serve` installs it. Assume
anything uploaded is installable by anyone who finds it.

Publishing and announcing are separate acts. The first releases are
deliberately quiet: the wheel exists, the README documents `pip install
m0serve`, and nothing is posted anywhere until the remaining release gates in
[ROADMAP.md](ROADMAP.md) are done.
