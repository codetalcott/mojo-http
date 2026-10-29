# Releases

m0serve and the `m0` package leave on a train: a minor version every
second Thursday, and a patch whenever a security fix or a regression in
the latest minor cannot wait for the next one.

## The next train

**1.17.0 leaves on Thursday 2026-11-05.** The train after it is 1.18.0 on
Thursday 2026-11-19.

What a train carries so far:

- [The open milestones](https://github.com/codetalcott/mojo-http/milestones):
  one per train, titled with its version and due on its Thursday, holding
  the pull requests and issues meant for it.
- [Unreleased](https://github.com/codetalcott/mojo-http/blob/main/CHANGELOG.md#unreleased),
  the changelog's section on `main` for what has merged since the last
  release, also [as plain text](https://raw.githubusercontent.com/codetalcott/mojo-http/main/CHANGELOG.md).

This site is rendered from the latest release, so its copy of this page
names the train after that release. The milestones are the live list.

## The cadence

- **A minor every second Thursday.** The dates do not move to fit the
  work: what has merged when a train leaves goes on it, and what has not
  waits for the next.
- **A train whose gates fail on its Thursday** leaves when they pass, and
  the train after it keeps its own date.
- **A patch any time** for a security fix or for a regression in the latest
  minor: the latest minor with the fix, and nothing else.
- **`m0` rides the same train.** It is released the same day as m0serve
  whenever anything it bundles has changed, which is nearly every train,
  since it carries the framework's source and the server's. A Mojo
  toolchain pin bump is an `m0` release, and rides a train like any change.

## What a version promises

- **SemVer.** From 1.0 the served contract does not break in a minor
  release: m0serve's flags and environment variables, the
  `M0-Hold`/`M0-Channel` response headers, and `m0pub.publish()`.
- **A behaviour change may ship on by default in a minor** when it keeps
  the contract, has a switch that turns it off, and is listed in the
  changelog under **Behaviour changes**, so it can be read before the
  upgrade.
- **A contract break waits for a major**, and the minor before it
  deprecates what is going: the old flag, variable or header keeps working,
  and prints one line at startup naming its replacement and the version
  that removes it.
- **`m0` is 0.x.** Its Mojo API may change in any `m0` minor, and each
  change is in the changelog.

## Which versions are supported

The latest minor. A fix ships on the next train, or as a patch on the
latest minor when it cannot wait; an older minor gets none. The contract is
what makes that safe: an upgrade within 1.x keeps every flag, variable,
header and call.

## Where to look

| for | read |
| --- | --- |
| the next train's date and version | this page |
| what is meant for a train | [the open milestones](https://github.com/codetalcott/mojo-http/milestones), or the API: [`/repos/codetalcott/mojo-http/milestones`](https://api.github.com/repos/codetalcott/mojo-http/milestones), each with a `title` and a `due_on` |
| what has merged since the last release | [Unreleased](https://github.com/codetalcott/mojo-http/blob/main/CHANGELOG.md#unreleased) on `main` |
| every released version and its date | PyPI's JSON, [`m0serve`](https://pypi.org/pypi/m0serve/json) and [`m0`](https://pypi.org/pypi/m0/json): `releases`, each file with its `upload_time` |
| what a release changed | [the changelog](../CHANGELOG.md) |
| how a release is made | [Releasing](RELEASING.md) |
| how each release's run went | [Release records](RELEASE_RECORDS.md) |
