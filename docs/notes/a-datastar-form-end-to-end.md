# A Datastar form, end to end — shipped 2026-09-12

> A design note from the engineering record. The fourth phase of the
> application layer's plan: the piece the plan named "the form arm is
> where a wrong spelling fails silently", and what a browser said about it.

**Where this comes from.** `Fragment[Datastar]` had spelled the form arm
since the two-transports round — `swap` on a `<form>` emits
`data-on:submit__prevent="@post('url', {contentType: 'form'})"` — and one
unit test pinned that string. No browser had sent it. The todo demo used
signals for everything (`data-bind:draft`, a `keydown` action posting the
store), so the one attribute whose correctness only a browser can judge
was the one attribute no browser had judged. SPEC N12 named the gap and
decision D21 rested on it.

**The piece.** The todo demo renames a todo in place. Each open todo's text
is now the one field of a `<form class="edit">`, and `swap("post",
url_for(EDIT, id))` on that form spells the submit action; done todos stay
`<s>text</s>`. The new route `POST /edit/:id` reads `form(req)`: `None` for
any body that is not `application/x-www-form-urlencoded`, answered as a
400 problem rather than read as a field named after itself (D13's point,
now on the wire); an empty `text` is a no-op like an empty draft; anything
else updates the row and broadcasts, so the renamed todo morphs into every
tab through the same `patch-elements` frame every other mutation uses. The
fragment stays one line, and `render_todos` stays the only renderer.

**The smoke** (`smoke-todo`, every pull request) posts the form the way a
browser would, urlencoded with `text=walk+the+dog`, and greps the frame
for the renamed value; greps the served page for the exact wire spelling,
`data-on:submit__prevent="@post(&#x27;/edit/2&#x27;, {contentType:
&#x27;form&#x27;})"`, escaped as the builder escapes it; and posts a JSON
body to the same route and insists on the 400 and on the value never
reaching a frame.

**The browser run** (`poe browser-datastar-form`, pre-release) starts the
demo, opens two Chromium tabs, adds a todo from the draft field and renames
it from the keyboard in one tab, records every request the bundle makes,
and waits for the other tab to morph. What the pinned bundle (v1.0.3)
sent, verbatim:

```
the field's action (D21): POST /add  content-type 'application/json'
  body '{"draft":"buy milk"}'
the form's submit (N12): POST /edit/1  content-type 'application/x-www-form-urlencoded'
  body 'text=buy+oat+milk'
```

Both requests carried `Datastar-Request: true`. The second tab showed the
renamed text without a reload.

**D21 confirmed.** The decision said a Datastar field's own action sends
the signal store, never the field, and that a form arm sends the fields.
The run shows exactly that split: the draft input's `keydown` action posted
the store as JSON with no form encoding, and the form's submit posted its
fields urlencoded with no signals. The ledger row now names this note and
its retiring condition is a bundle whose field actions send the field
alone, which is what the run would show first.

**Pre-release, not CI.** The run needs Chromium, which the CI runners do
not carry, and what it guards moves only when the bundle pin moves (D20).
The smoke stays the every-pull-request gate for the server's half. The
run costs ten seconds and prints the two bodies as its record, so a moved
pin gets its evidence in the release that ships it; `docs/RELEASING.md`
lists it beside the other pre-release steps.

**Not claimed.** Whether a half-typed rename survives a broadcast from
another tab: Datastar morphs `#todos` by id and this run typed and
submitted before any other tab wrote, so the interaction of a morph with
an input mid-edit was not exercised. Multipart stays D16. And one route,
one field: the form arm is proven for the shape `form(req)` decodes, not
for `enctype="multipart/form-data"`, which the bundle sends as multipart
and `form(req)` refuses.
