# Traceability: stable ids, then declared coverage

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

[SPEC.md](../SPEC.md) is a requirements traceability matrix -- the standard
artifact in safety-critical software, whose defining property is that it traces
BOTH ways: every capability to its evidence, and every piece of evidence back
to a capability. That second direction is the half most homegrown versions omit
and the half this one has, over two closed sets (the CI steps in `test.yml`,
the flags `cli.mojo` accepts).

It also has a structural weakness, and the 2026-08-30 audit is the evidence.
The sheet asserts things ABOUT tests, from outside them. The established
tools -- shtracer, TRLC, and every RTM that survives contact with a real
codebase -- put the tag IN the test and generate the matrix. Every defect that
audit found is a symptom of the direction:

- six rows cited a gate that asserted something else, which cannot happen when
  the assertion declares its own coverage;
- two sabotages broke because they quoted a row that was legitimately
  re-pointed, because rows are keyed by prose;
- "the checker cannot read a test's meaning", stated on the page as a limit, is
  not a law -- it is a consequence of authoring the claim away from the
  assertion.

## Phase 1 -- stable ids (done 2026-08-30)

Every row carries a permanent id, `<section letter><number>`, in its own
column. Ids are assigned once, never renumbered, and never reused: a deleted
row's id is retired rather than recycled, so an id in an old commit, an issue
or a conversation still means what it meant. Prose becomes freely editable,
which it should be -- and the sabotages key on ids, which is what stops them
breaking every time a capability is reworded.

Enforced: an id on every row, unique, and its letter matching its section. NOT
enforced, and left as a convention with the reason written down: never reusing
a retired id, which cannot be checked without carrying a ledger that is itself
a second source of truth to keep in step.

## Phase 2 -- declared coverage, not asserted citation

Invert the direction. A gate declares what it covers, next to the assertion,
written by the person who knows what was asserted:

- Mojo tests: a `covers: A7` line in the test's docstring, greppable.
- Smokes: `emit.py --covers A7`, which means coverage is RECORDED BY A REAL RUN
  rather than claimed statically. The emitter for this already exists.

`check_spec_sheet` then collapses from nine rules about the shape of a citation
to two: every `verified` row was covered by a real run, and every declared id
exists. The class of defect the audit spent its time on stops being possible.

**Done, 2026-09-01** (SPEC F12), in one migration rather than incrementally
-- it was fully scriptable, which the incremental plan had underestimated:
every one of the 119 `verified (every PR)` rows now declares its coverage in
its gate (a `covers:` docstring line in the cited test for the 39 unit-cited
rows, a `scripts/emit.py --covers` call in what the cited step runs for the
80 step-cited ones -- also recorded by the real run through `$M0_RESULTS`,
where the summary renders them as a tally). Two new rules run in
`check_spec_sheet`: every declared id names a row that exists, and every
gated row's declaration AGREES with its citation -- declared only elsewhere
is the mis-citation the audit spent its time on, now a red build. Four new
sabotages revert them.

One refinement to what this section predicted, recorded rather than papered
over: the nine citation-shape rules did NOT collapse to two. They guard
properties a declaration cannot -- the cadence is real, the cited step
carries no `if:`, and the two closed sets (every smoke step cited by some
row, every CLI flag named by one) hold in both directions -- so they stay,
with the declaration rules beside them. Weekly and pre-release rows keep
declared-static citations, their runs being absent from PR CI; the checker
exempts exactly those cadences and the rollup says so.

The argument this section made for the change held: a test added next month
that quietly drifts from its row is now a disagreement between a declaration
and a citation, which is a named failure rather than nothing.
