# A trait and a directory name, 2026-09-15

> **Fixed upstream.** Mojo 1.1.0 records a trait's identity so that a
> package name differing from its source directory costs nothing, and
> this repo pinned it on 2026-09-18. `poe check-mojoc-trait` is now a
> regression guard rather than a countdown. The decisions this page
> describes still stand, because the code has not moved yet; see
> [The pin moves to Mojo 1.1.0](the-pin-moves-to-1-1-0.md).

> A correction from the engineering record. For three weeks this repo
> believed a language limitation that does not exist, and shaped four
> decisions around it. This is what the limitation actually is, how it was
> found, and what it costs to leave in place.

## What was believed

From 2026-08-28: *an app cannot conform to a trait defined in a precompiled
package*. The evidence was two experiments. `PoolHandler`, defined in
`m0-http/src/mojo_pool.mojo`, was moved into the source-resolved fork because
an app's conformance compiled, was accepted, and then failed at the generic
call site with *"struct 'X' does not have witness table for trait"*. Then
`PageShell`, a trait in `src/fragment.mojo` with one method naming only
prelude types, failed the same way — which killed the "two type identities"
explanation the first case had suggested, and left the discriminant
unestablished. `poe check-mojoc-trait` was written to hold the claim and to
flip if it ever lifted.

Four things were decided on that basis: `HTTPService` and `PoolHandler` live
in `lightbug_http/` rather than `src/` (CLAUDE.md states it as a rule), the
page shell is a `thin` function rather than a `PageShell` (D12), and
`ViewService` does not conform to `PoolHandler` (D14).

## What it actually is

The package's NAME against the SOURCE DIRECTORY it was compiled from.
Identical twelve-line code, one difference:

```
src/pkg/      ->  pkg.mojoc     conformance compiles, prints 1
src/pkg_src/  ->  pkg.mojoc     struct 'app::S' does not have witness
                                table for trait 'pkg_src::lib::T'
```

A trait's identity is recorded under the directory's name; a consumer
resolves it under the package's; when they differ nothing matches. Every
package here runs `mojo precompile src -o <name>.mojoc`, so every one of them
has the mismatch — and the error message has been saying so the whole time:
`trait 'src::fragment::PageShell'`, not `m0_http::fragment::PageShell`.

Verified on the real packages: with `packages/m0-http/src` renamed to
`m0_http` and rebuilt, an app conforming to `PageShell` compiles and runs
against the `.mojoc` **alone**, with no source directory anywhere on the
include path. An app conforming to `HTTPService` compiles against a
precompiled `lightbug_http.mojoc` too — that directory is already named after
its package.

It is fixed upstream: on Mojo nightly `1.2.0.dev2026091505` both spellings
work, so there is nothing to file and the workarounds have an end date.

## Why it survived two investigations

Both experiments varied the wrong thing. The first changed the types a
trait's methods named; the second removed them entirely. Neither changed the
one thing that mattered, because nothing suggested a package's directory name
was load-bearing — the manual says the opposite twice, that a package name
"can differ from the directory name" and that source-versus-`.mojoc` import
"makes no real difference to Mojo".

The probe inherited the same blind spot. It had a control (`Views[S]` over an
app type, which has always worked) but only one failing arm, so it could
report *that* conformance failed and never *why*. A probe with one failing
arm cannot tell a cause from a coincidence.

## Why the rename is not the fix

Renaming `src/` to the package name works, and it is still the wrong move
today:

- **A source directory beside a `.mojoc` of the same name shadows it.**
  Measured: with both on one `-I` root, a marker function present only in the
  source tree resolves. So the rename would silently stop every consumer from
  using the `.mojoc` at all, and `build-http` would become decorative. Keeping
  the artifact meaningful means relocating it and rewriting every `-I` chain.
- **The blast radius is wide**: seven `precompile src` tasks, forty path
  references across `pyproject.toml`, `CLAUDE.md`, docs and scripts, and
  fifty-eight test files importing `src.*`. Several of those scripts sabotage
  by matching EXACT source lines, and each package has a
  `test_resolution.mojo` whose whole job is policing this ambiguity.
- **The payoff is one item** — `PageShell` as a real trait — and the pin
  moving delivers it for nothing.

So the decision is to wait, and to make sure the tree says what is true in
the meantime.

## What the probe checks now

Four cases rather than one, because the pair is the argument:

| case | must |
|---|---|
| an app conforming to `m0_http.fragment.PageShell` (`src` → `m0_http`) | be REFUSED |
| the same synthetic source, directory and package name agreeing | COMPILE |
| that synthetic source from a differently named directory | be REFUSED |
| `Views[S]` over an app type | COMPILE |

The second and third are one source compiled two ways, which is what makes
the name the cause rather than a correlate. The fourth is what stops a stale
or broken `.mojoc` reading as the limitation. Sabotaging either synthetic arm
is caught with its own message.

When the first and third compile, the toolchain has fixed it: the check exits
1, D12 and D14 can retire, and app-facing traits no longer need the fork for
this reason.
