# A two-weekly train — 2026-10-29

A design note from the engineering record. [Releases](../RELEASES.md) is
the policy it produced.

## The question

Releases followed the work. From 1.0.0 on 2026-09-09 to 1.16.0 on
2026-10-23 there were 17, one every 2.6 days on average, in bursts: four
between 10-07 and 10-11, then 12 days to 1.16.0. Nothing said when the
next would leave or what it would carry. The site deploys only on a
release, so a reader of m0serve.dev never saw `[Unreleased]`. The
roadmap's Planned section said nothing was planned, because new work
arrives as SPEC rows with no date. The repository used no GitHub
milestones, and `llms.txt` said nothing of releases.

A release is not free. RELEASING.md's gates take about 2.5 hours on a
cool machine and in the Linux container, and CI about 45 minutes after
the bump. A re-soak is due once the soak is three minors behind, and a
bench re-record once the benches are two behind. A cadence has to be one
those costs can sustain.

## What was decided

The owner, 2026-10-29:

- **A minor every second Thursday**, from 1.17.0 on 2026-11-05, and a patch
  any time for a security fix or a regression in the latest minor.
  Thursday is two days after the Tuesday nightly canary, so a toolchain
  break is known by the day, and leaves a working day before the weekend.
- **`m0` on the same train**, released the same day whenever anything it
  bundles changed. It carries the framework's source and the server's, so
  that is nearly every train.
- **The latest minor is the one supported.** An older minor gets no fix,
  which the served contract makes safe within 1.x.
- **A behaviour change may ship on by default in a minor** when it keeps
  the contract, has an off switch, and is listed under **Behaviour
  changes**. A contract break waits for a major, after one minor of
  deprecation. #642, the comment after an SSE event with
  `M0_SSE_FLUSH_MS=0` to turn it off, is the case that prompted the rule.
- **What is coming is linked, not deployed.** The site keeps its rule: it
  renders at a release, because its pages describe the server the release
  serves. The policy page and `llms.txt` give the next train's version and
  date and link to the milestones and to `main`'s `[Unreleased]`, which
  are live.

## What each artifact told a reader about the future

| artifact | before | how it went stale | now |
| --- | --- | --- | --- |
| `CHANGELOG.md` `[Unreleased]` | what has merged, on GitHub only | never on the site between releases | linked raw from `llms.txt` and the policy page |
| `docs/ROADMAP.md`, Planned | nothing: work arrives as SPEC rows | — | unchanged; the milestones carry the dates |
| `docs/RELEASING.md` | how, never when | — | a train section: the day's steps and what moves |
| GitHub milestones | none | — | one per train, the next two always open |
| `llms.txt` | the operating contract, no releases | — | a Releases section naming the next train |
| `poe milestones` | the soak against the current version | the soak's staleness surfaced only after the bump | the next train, its days, and a soak stale at its version |
| the site | the latest release | by design, until the next | unchanged, plus the policy page |
| GitHub releases | notes linking the changelog at the tag | — | unchanged |

## How the date stays honest

`check-docs` holds the two sentences on the policy page, and the one in
`llms.txt`, to the version and to the calendar's shape. The next train is
the minor after the version in `pyproject.toml`, or the major after it.
The train after it is the minor after that. Both leave on Thursdays, a
fortnight apart, and `llms.txt` names the same train. A release pull
request bumps the version, so the sentences then name a train that has
left, and the check refuses the pull request until they move on. Its
selftest reverts each rule against the committed page.

The check has no clock. It is the one required check on `main`, and a
rule that turned red with the date would block every pull request, the
release's own included. The clock is `poe milestones`', which prints on
every `Tests` run and in every session that plans work: the days to the
train, LATE once it has passed, and a soak that would be stale at the
train's version.

## Not yet done

- **RELEASING.md mixes the process with records of past releases**, which
  makes the steps hard to find for a person or an agent. Moving the records
  to a page of their own is the next piece.
- **A machine-readable releases file**, the versions and dates beside
  `spec.json`, waits on whether the milestones API is enough for the agents
  that read it.
- **The first train runs on all this:** 1.17.0, which needs the re-soak
  (both soaks are recorded at 1.14.0).
