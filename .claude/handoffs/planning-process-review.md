# TODO: replace session-scoped planning with tracked targets

Raised by the user 2026-08-31, immediately after A11. **Not yet done** — this
file exists so the request survives the session that received it, which is
precisely the problem it describes.

## The ask, in the user's terms

> Ideally, we would have clear and tracked goals/targets guiding each
> session, not relying on my memory or the context of an individual session.
> We may need to define a beta release, or 1.0 release, to drive the process.

## Why it is a real gap

Three artifacts exist and none of them is a plan:

- **`docs/SPEC.md`** — 149 rows with statuses. The closest thing to tracked
  targets, and it is machine-checked. But it says what IS, never what must
  become true, so it cannot answer "what is left".
- **`docs/ROADMAP.md`** — 2000+ lines of narrative record, organised by
  released / planned / open questions / known issues. Excellent history,
  no ordering and no finish line.
- **`.claude/handoffs/*.md`** — written by a session, for a session.
  `spec-next-items.md` worked well and is now exhausted; nothing says what
  comes after it except a human remembering.

So the direction of the work currently lives in the user's head, and each
session reconstructs it. That is the thing to fix.

## The shape a fix probably takes (to be argued, not assumed)

SPEC.md already holds the data; what it lacks is a **milestone predicate**.
If each row carried the milestone it belongs to, then "what is left for 1.0"
becomes a query rather than a memory, and `check-docs` can report it on
every PR — the same ratchet philosophy the repo already applies to warning
counts and doc facts.

Open questions for whoever takes this:

- What does 1.0 MEAN here? Candidate: every `A`/`B`/`C` row `verified` or
  `out of scope`, no `implemented` row without a gate, no Known issue.
- Is there a beta tier, and is it a subset of rows or a soak requirement?
- Does the milestone live in SPEC.md as a column, or in a separate file
  that references row ids? A column changes 149 rows; a file keeps the
  sheet stable and is itself checkable.
- What stops it rotting? The repo's answer to that question is always the
  same: a checker, plus a sabotage that proves the checker bites.

## Evidence worth using

The `implemented`-without-a-gate rows are the strongest signal available.
Gating one found a real bug three times in three tries (A4's linger, I16's
close codes, A11's two Expect defects). If a milestone needs a first
ordering rule, "no `implemented` row ships without a gate" is one the
evidence already supports.
