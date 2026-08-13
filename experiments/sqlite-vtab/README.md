# SQLite virtual tables in pure Mojo — feasibility spike

Working code, not shipped code. Nothing here is built by `build-all` or picked
up by any `test-*` glob; `packages/` does not import it. Findings and the
verdict live in [docs/sqlite-vtab-feasibility.md](../../docs/sqlite-vtab-feasibility.md).

The question was whether to port SQLite's `ext/misc/carray.c` and modify it to
read Mojo struct memory. The answer turned out to be that no C is needed at
all: `libsqlite3` already exports everything required, and Mojo 1.0 can supply
C-callable function pointers, so a virtual table module can be registered
in-process from Mojo on a live `Connection`.

## Running them

Each is standalone and needs the same link flags as `test-sqlite`:

```bash
out=$(mktemp -d)
for f in experiments/sqlite-vtab/spike_*.mojo; do
  mojo build -I packages/m0-sqlite -Xlinker -lsqlite3 "$f" -o "$out/$(basename "$f" .mojo)"
  "$out/$(basename "$f" .mojo)"
done
```

## What each one establishes

| Spike | Question | Result |
|---|---|---|
| `spike_s1.mojo` | Can Mojo hand SQLite a C-callable function pointer it calls back correctly? | Yes. A Mojo `abi("C")` function registered via `sqlite3_create_function_v2`; `SELECT mojo_double(21)` returns 42, and it is invoked per row inside an aggregate. |
| `spike_s2.mojo` | Can a whole `sqlite3_module` be built and registered from Mojo? | Yes. An eponymous read-only table-valued function `mojo_int64(ptr, count)` streaming a Mojo `List[Int]`, covering scan, aggregate, `IN`-clause, and statement reuse with a different array. |
| `spike_s3.mojo` | Does it pay for itself? | Bulk ingest ~2.96x. `IN`-clause 1.63–1.99x against rebuilt placeholders, only 1.16–1.34x against `json_each`. |

## The three Mojo 1.0 mechanics that make it work

Established by compiler probe, since none of this is in the pinned docs:

1. **C ABI on a definition** is a function effect between the parameter list and
   the return type: `def cb(a: Int) abi("C") -> Int:`. It is `abi("C")` on the
   definition and `thin abi("C")` on the corresponding *type* — `thin` is
   rejected on a definition ("function effect 'thin' must only be used on
   function types").

2. **A function pointer type** is written
   `comptime XFilterFn = def (Int, c_int, Int, c_int, Int) thin abi("C") -> c_int`,
   and a matching `def` assigns to it directly. Storing one into raw memory
   works through a typed pointer:
   `UnsafePointer[XFilterFn, MutAnyOrigin](unsafe_from_address=slot)[unsafe_offset=0] = x_filter`.
   That is how the module's 24 callback slots get filled without ever needing to
   convert a function to an integer.

3. **A `comptime` string literal has a stable, NUL-terminated static address.**
   That matters because `sqlite3_bind_pointer` *retains* its type-tag string
   pointer, so the tag cannot be a transient `List[UInt8]` from `c_string()`.

The `sqlite3_module`, `sqlite3_vtab`, `sqlite3_vtab_cursor`, and
`sqlite3_index_info` structs are all handled as flat word buffers rather than
Mojo structs, following `lightbug_http/c/epoll.mojo` — a struct whose size is
wrong by four bytes corrupts everything downstream in silence.

## The hazard these spikes exposed

`sqlite3_bind_pointer` lends SQLite raw Mojo memory for the life of the
statement, and Mojo destroys a value at its **last syntactic use**. So this is
silently wrong:

```mojo
bind_array(q, 1, data)
q.bind_int(2, len(data))   # <- last use of `data`; it is freed HERE
_ = q.step()               # <- SQLite now reads freed memory
```

It does not crash. The allocator writes a freelist pointer into the block's
first word, so element 0 comes back as a heap address and every other element
reads correctly — which is exactly how it presented: `sum` was garbage while
`count(*)` was right. Each spike carries an explicit `_ = len(data)` keep-alive
after the step, which is a demonstration crutch, not an API.

Every existing binder in `m0-sqlite` passes `SQLITE_TRANSIENT` so that no Mojo
buffer ever has to outlive a call. A pointer-binding API breaks that invariant
and needs a real answer — a borrow that the type system enforces — before any
of this belongs in `packages/`.
