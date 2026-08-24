# Releasing

Releases are tag-driven: pushing a `v*` tag runs the `Release` workflow
(`.github/workflows/release.yml`), which builds `libm0core` on Linux and
macOS, proves each artifact through the same `ctypes` smoke that CI runs on
every commit, and publishes a GitHub release with both attached.

The steps, in order:

1. **Update [CHANGELOG.md](../CHANGELOG.md).** Add a `## [X.Y.Z] — date`
   section at the top and a link reference at the bottom. The release notes
   point here, so this is the document of record.
2. **Bump `version` in `pyproject.toml`** to match, and `M0SERVE_VERSION`
   in `packages/m0-wsgi/src/cli.mojo` — `smoke-serve` asserts the two agree,
   so CI catches a bump that forgot one. Then run `uv lock` so `uv.lock`'s
   own project version follows (a bare `uv run` later will rewrite it
   otherwise).
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
     run can). Delete the branch afterwards.

5. **Check the artifact is loadable off this machine**: `poe build-ffi &&
   poe check-ffi-portable`. This is currently EXPECTED TO FAIL — every
   release so far ships a `libm0core` that only loads on its build machine,
   because `smoke-ffi` tests it in the build tree where the defect cannot
   appear. See [FFI_DISTRIBUTION.md](FFI_DISTRIBUTION.md) for the analysis,
   the proven fix, and the licensing question blocking the last step. It is
   a diagnostic, not a gate, until that fix lands.

6. The workflow does the rest. If a build or the artifact proof fails, no
   release is created — fix, delete the tag if it was pushed
   (`git push origin :vX.Y.Z`), and re-run.

Versioning is SemVer with the standard pre-1.0 caveat, stated in the
README: minor versions may break the API. The version lives only in
`pyproject.toml` and the changelog — packages carry no version constant to
drift out of sync.
