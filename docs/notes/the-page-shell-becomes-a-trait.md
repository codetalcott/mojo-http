# The page shell becomes a trait — 2026-09-18

DECISIONS D12 made the document shell a `thin` function over a separate
context struct:

```mojo
page_or_fragment(req, render_list(store), Site("notes"), wrap)
```

It was designed as a trait and went to that form because on Mojo 1.0 an
application's conformance to a trait it imported from a `.mojoc` was
accepted and its witness table never emitted. That was never the package
boundary: a package compiled from a directory named other than the package
recorded its traits under the DIRECTORY's name, and every package here
runs `mojo precompile src -o <name>.mojoc`
([a-trait-and-a-directory-name](a-trait-and-a-directory-name.md)). Mojo
1.1.0 fixed it and the pin moved the same day
([the-pin-moves-to-1-1-0](the-pin-moves-to-1-1-0.md)). D12's retiring
condition read "`page_or_fragment` taking a `PageShell` and the apps moved
onto it". This is the record of that round.

## The probe

`check-mojoc-trait`'s `mismatch` arm already conformed an app struct to
`m0_http.fragment.PageShell` and called a generic helper, `wrap_with`,
with it. What it did not prove is the shape this round ships: the
conformance crossing the `.mojoc` as an argument to the real API, with
`wrap` called only on the document branch. So that was built first, as an
application compiled against the built package.

| case | answer |
|---|---|
| `Site(PageShell)` with a field, document branch | `<title>n</title><p>x</p>` |
| the same, fragment branch (`HX-Request: true`) | `<p>x</p>` |
| `Bare(PageShell)` with NO fields, document branch | `<html><p>x</p></html>` |
| the same, fragment branch | `<p>x</p>` |
| `status=404` through the document branch | `404` |

The fieldless arm is the one that decided the round's open question.

## Replace, not overload

The `thin` form shipped in four releases (v1.1.0 through v1.4.0), so
keeping both was the safe option and was considered. It was rejected, and
the fieldless probe is why: the only thing the function form buys is a
shell that carries no context, and such a shell is a struct with no
fields, which conforms trivially and costs nothing. Two forms would have
meant a module docstring that had to say when to use which, with no honest
answer — and this tree has already paid for one duplicated function twice
(`split_data_lines`, whose copy kept a fixed trap for a release).

A Mojo signature is outside the served contract CHANGELOG states
(`m0serve`'s flags and environment, the `M0-Hold`/`M0-Channel` headers,
`m0pub.publish()`), so this is not a SemVer break; it is a documented API
change and goes under **Changed**. The one call shape that changes is an
application's, and the migration is mechanical: the context struct
conforms to `PageShell`, the shell function becomes its `wrap` method, and
the argument goes.

## What did not change

`smoke-fragment-notes` is the wire gate, and the point of the round was
that it should not move. It passes, which is the gate; what the gate does
not do is compare bytes, so that was done separately. Twenty-one request
shapes were driven against the application binary built at `60b205a` and
again against the refactored one — every one of the app's NINE
`page_or_fragment` call sites, in both representations where it has two,
plus both page-forcing headers, the styled 404, the login page, the 401
fragment, `OPTIONS` and a bad method — and their bodies and headers, 42
files, compared byte for byte. Only the session cookie and the CSRF token
were normalised, both being derived from the issue time. All 42 are
identical.

Covering the writes took a second pass: reads alone reach five of the nine
call sites, and `create`, `delete`, and `login` and `logout` answered as
fragments are the four that need a POST with a valid token to reach at
all. A comparison that had stopped at the reads would have been a true
statement about a smaller thing than it sounded like.

## The generic body is run, not merely compiled

Mojo checks a generic's body where it is instantiated, so a
`page_or_fragment[S: PageShell]` that `test_fragment.mojo` only compiles
would look tested and be nothing of the kind. The document branch was
therefore sabotaged to skip `wrap` altogether. Three of the nine tests
fail — `test_page_or_fragment_wraps_only_without_the_header`,
`test_a_history_restore_is_a_page` and `test_a_boosted_request_is_a_page`
— each naming the missing shell in the body it got. The branch is
exercised.

## `check-mojoc-trait` keeps four arms

`wrap_with` existed only so the probe had a generic to instantiate.
Once `page_or_fragment` is that generic, it has no reason to exist and is
gone; the `mismatch` arm calls the real API instead. The arm is NOT
deleted — its failure message names D7 and D28 as well as D12, and it is
the tree's only standing evidence that the 1.1.0 fix is still there. It
was sabotaged once by hand after the re-point (the conformance's method
misnamed) and reported `REGRESSED`, exit 1, naming what it costs.

## What this leaves

D7 is the last of the three moves the pin unblocked: `Vocabulary` opened
to an application-defined conformance, with a gate that an app outside
this repo can emit a third library's attributes. `PageShell` is now
exported from `m0_http`, which is what an application-defined `Vocabulary`
would need too.
