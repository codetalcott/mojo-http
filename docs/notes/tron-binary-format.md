# Feasibility: TRON as a format this repo speaks, 2026-09-13

> A design note from the engineering record: whether mojo-http should
> encode or decode [TRON](https://github.com/starfederation/tron), the
> trie-based binary format for JSON-compatible data, and what would have
> to become true for the answer to change.

Read from the spec, the wiki and the repository front page on 2026-09-13.
Nothing was built and no vector was run; where a number appears it is
TRON's own, taken from its performance page, and labelled as such.

## The question

TRON ("TRie Object Notation") represents JSON's eight value shapes in a
binary document: a 4-byte `TRON` magic, a body of nodes addressed by
absolute little-endian u32, and an 8-byte footer holding the current and
previous root addresses. Maps are a hash array mapped trie over xxh32
(seed 0) of the UTF-8 key bytes, 16-way, `slot = (hash >> (depth*4)) & 0xF`
to a maximum depth of 7, where colliding keys share a leaf sorted
lexicographically. Arrays are a vector trie over the index nibbles.
Updates append: the changed path is rewritten leaf-to-root, unchanged
subtrees are shared by address, the new root goes in the footer and the
old one stays reachable through `prev_root_addr`. Encoding is canonical —
one logical value, one byte sequence — via post-order traversal with slots
visited ascending and a minimal root shift.

Its stated targets are wire protocols, database BLOB columns, and partial
updates. This repo has an HTTP server, an SSE and WebSocket transport, a
Datastar package and two database bindings, so all three touch something
here. The question is whether any of them touch something that wants it.

## Verdict

**Do not build it. Watch one condition: Datastar adopting it on the
wire.** The feasibility is fine — better than expected, for one specific
reason given below. The case for doing it is the part that is missing.

Five findings, heaviest first.

### 1. The format says it will break

The repository front page reads "Work in progress. Expect breaking changes
as the spec solidifies." Go is complete, TypeScript has the core, Rust is
in progress; 35 stars and 41 commits on main. There is no version number
on the format and no stability statement anywhere in the spec or the wiki.

That is disqualifying on its own here, because of what this tree promises
about anything it ships: every capability names the gate that proves it,
and `poe milestones` refuses a row that is merely `implemented`. Gating an
encoder means pinning a byte-for-byte expectation, and a spec that
announces it will move turns that gate into a standing re-chase. The
precedent is [D20](../DECISIONS.md) — Datastar pinned at 1.0.3, re-check
the version before any vocabulary work — and it only works because
Datastar has releases to pin. TRON has nothing to write in that column.

### 2. Nothing in the tree consumes it

Taking its three stated use cases in turn:

**Wire.** What this server sends is HTML fragments, SSE frames and small
JSON replies. SSE is `text/event-stream`: UTF-8, line-oriented, delimited
by `\n\n`. A binary payload cannot ride it at all without base64, which is
+33% on a format that is already larger than JSON (finding 4), and would
land in exactly the splitters that G14 has already had to make
byte-safe twice (`split_sse_lines`, and `m0-datastar`'s deliberate copy
`split_data_lines`). The Datastar down-channel is SSE, so TRON on it is
not expressible today in either package.

**Inbound.** The upward half of Datastar is the browser posting
`JSON.stringify` of its signal store — `read_signals` in
`m0-datastar/src/signals.mojo` returns that text verbatim. The server does
not choose that format; the client bundle does. Nothing on this side can
adopt TRON unilaterally.

**Database columns.** This is the fit that is real: a document per row in
a BLOB, read by address without decoding the rest, updated copy-on-write.
`m0-sqlite` and `m0-postgres` are both here. But no application in the
tree stores a document — `apps/datastar_todo` is columns plus an append
event log (SPEC O5), and the storage rows are about durability and wire
decoding, not about document shape. A format with no consumer is the
`implemented` status the milestone definition exists to refuse.

### 3. The headline advantage is measured against something this repo does not do

TRON's front number is a 21x read against JSON: 861 MB/s to 33.7, on a
GeoJSON fixture, `go test -bench` on a Ryzen 9 6900HX. The comparand is
Go's `encoding/json` — reflection-driven unmarshal of the whole document
into a value tree, allocating as it goes, which is why the same table
reports 53x less memory for TRON.

m0-core never does that. `parse_json_field` walks the bytes structurally,
tracking string and depth state, and returns the one field asked for;
`signals.mojo` states the reason in its own docstring, that callers pay
only for the fields they actually read. So the work TRON's random access
avoids is work this tree already avoids, by a route that costs one file
and no format change. The honest comparison — TRON's addressed lookup
against a byte scan for one key over a 2 KB signal store — is not on
TRON's page, and both sides of it would be bandwidth-bound and
allocation-free. There is no reason to expect 21x, or anything like it,
for the shape this repo actually has.

### 4. The bytes get worse

TRON's own figures on the same fixture: 2.60 KB raw against JSON's 2.15 KB
(+21%), and 0.98 KB against 0.48 KB under zstd — twice the compressed
size. Its first non-goal is "a compressor"; it is explicitly designed to
be paired with one, and pays its random-access cost in space.

For a document sitting in a BLOB that is fine, and the trade is the point.
For anything crossing HTTP it is the wrong trade: this server compresses
nothing itself and `docs/RUNNING.md` ("In front of it") expects an nginx,
a Caddy or a load balancer there, which is where compression lands.
Against that, adopting TRON doubles what goes over the link — before the
base64 that SSE would additionally require.

### 5. The expensive half is a JSON model this repo deliberately does not have

Encoding JSON to TRON needs a full JSON parser and a document model to
parse into: TRON's canonical encoder has to see the whole value to choose
a minimal root shift, sort collision leaves and emit post-order.
`json_parse.mojo` is a field extractor, and `signals.mojo` records that as
a choice — "so the package stays free of a JSON model".

So a TRON package that interoperates with JSON brings a JSON value type
and a complete parser with it, and that is the bulk of the work rather
than the trie. It would also be the first place in this tree where a
recursive value type is needed, which in a language with value semantics
and no automatic boxing means inventing an indirection.

## What is cheap, which is the surprise

The feasibility half came out better than the case-for half, and two
pieces are worth writing down in case the condition below ever holds.

**The hash is already here, and already proven.** TRON's map hash is
xxh32 with seed 0 over the UTF-8 key bytes. `m0-core/src/hashing.mojo` has
exactly that — `xxhash32(input, seed=0)`, `_xxhash32_ptr` over a raw span
for the byte-oriented path, `xxhash32_batch`, and a C-ABI export gated by
`test_ffi_exports.mojo`. `test_hashing.mojo:test_xxhash32_empty` asserts
`0x02CC5D05`, the published empty-input vector, so the agreement with
upstream xxHash is pinned rather than assumed. The dependency that is
usually the tedious part of adopting a HAMT format is done.

**A reader needs no value model at all**, which sidesteps finding 5
entirely for the decode direction. A TRON document is an arena of
u32-addressed nodes; a reader is a `Span[UInt8]` plus an address, and a
lookup is nibble-slicing the hash, testing a bitmap bit and popcount-
indexing into the child addresses. No allocation, no recursion, no
`Variant`, nothing to own — the format's own addressing *is* the
indirection a recursive Mojo value would have had to invent. That is a
good fit for m0-core's zero-dependency shape, and it is the piece a
Datastar client sending TRON signals would actually need.

**Conformance vectors exist and are cross-language.** `tron-shared` ships
`shared/testdata/tron/value_nodes.json` and `documents.json` as
`{"bytes": <hex>, "parsed": {...}}` pairs. The `bytes` half alone gates
scalars and packed text without needing any JSON model; checking against
`parsed` needs the parser from finding 5, so the vector set splits along
the same line the work does.

Rough shape if it were built: scalars and the packed/unpacked text tag are
small, the vector trie is moderate, the HAMT with its depth-7 collision
leaves is moderate, and the canonical ordering rules — minimal root shift,
ascending slots, post-order, root last — are where the determinism bugs
would live and where the vectors earn their keep. A read-only decoder in
m0-core is a plausible small package. A canonical encoder plus the JSON
bridge is several times that, and carries the parser.

## What would change the answer

**Datastar adopting TRON as a signal format.** Both are Star Federation
projects and TRON's first stated use case is wire protocols, so the
inference is available — but it is only an inference: neither TRON's
README, its spec, nor its wiki mentions Datastar anywhere, and Datastar
1.0.3 is JSON in both directions. If a Datastar release ships TRON
signals, the calculus inverts completely: the format becomes pinned by a
client this repo already tracks under D20, the scope is bounded by what
that client sends, the decode direction is the cheap direction above, and
`m0-datastar` needs it to keep working at all. Re-read this note then; the
rest of it is about a format with no consumer, and that would no longer be
the case.

**An application in the tree that stores a document per row and updates
one field of it.** That is the BLOB case in finding 2 acquiring the
consumer it lacks, and it is the standard this tree applies to every other
deferred piece — D16 waits for an app that uploads a file, D17 for three
apps writing the same setter.

Neither holds on 2026-09-13.

## Sources

- [Overview and implementation status](https://deepwiki.com/starfederation/tron)
- [Design goals and non-goals](https://deepwiki.com/starfederation/tron/1.1-design-goals-and-non-goals)
- [Performance characteristics](https://deepwiki.com/starfederation/tron/1.2-performance-characteristics)
- [Binary format specification](https://deepwiki.com/starfederation/tron/3-binary-format-specification)
- [Implementation guide and test data](https://deepwiki.com/starfederation/tron/5-implementation-guide)
- [starfederation/tron](https://github.com/starfederation/tron)
