# Releasing

Releases are tag-driven: pushing a `v*` tag runs the `Release` workflow
(`.github/workflows/release.yml`), which builds `libm0core` on Linux and
macOS, proves each artifact through the same `ctypes` smoke that CI runs on
every commit, and publishes a GitHub release with both attached.

The steps, in order:

1. **Update [CHANGELOG.md](../CHANGELOG.md).** Add a `## [X.Y.Z] — date`
   section at the top and a link reference at the bottom. The release notes
   point here, so this is the document of record.
2. **Bump `version` in `pyproject.toml`** to match.
3. **Land those changes on `main`** through an ordinary PR — CI green first,
   like any change.
4. **Tag the merge commit and push the tag:**

   ```bash
   git tag vX.Y.Z <merge-commit>
   git push origin vX.Y.Z
   ```

5. The workflow does the rest. If a build or the artifact proof fails, no
   release is created — fix, delete the tag (`git push origin :vX.Y.Z`),
   and re-tag.

Versioning is SemVer with the standard pre-1.0 caveat, stated in the
README: minor versions may break the API. The version lives only in
`pyproject.toml` and the changelog — packages carry no version constant to
drift out of sync.
