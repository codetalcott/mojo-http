/* Compile-time proof of every struct offset src/vtab.mojo hardcodes.
 *
 * src/vtab.mojo treats sqlite3_module, sqlite3_vtab, sqlite3_vtab_cursor and
 * sqlite3_index_info as flat word buffers (the epoll.mojo approach), so its
 * correctness rests entirely on offsets that are invisible to the Mojo
 * compiler. This file re-derives them from the real headers via offsetof and
 * fails if any disagrees. A wrong offset here does not crash — it silently
 * corrupts every row after the first, which is why this is a build gate and
 * not a note.
 *
 * `uv run poe verify-vtab-layout` runs it for the host, and `test-sqlite`
 * runs it before the Mojo tests. Native, not cross-compiled, because that is
 * what checks the sqlite3.h actually installed on the machine — the macOS SDK
 * copy on one CI runner and libsqlite3-dev's on the other, which between them
 * are the two headers this repo is ever built against.
 *
 * Before adding a target the CI matrix does not cover, sweep it by hand. This
 * needs a sysroot carrying sqlite3.h for each triple, which is why it is not
 * the gate:
 *
 *   for t in x86_64-linux-gnu aarch64-linux-gnu arm64-apple-macos; do
 *     clang -fsyntax-only -target $t packages/m0-sqlite/test/verify_layout.c \
 *       && echo "$t OK"
 *   done
 *
 * Add a triple there rather than trusting that "64-bit is 64-bit": this repo
 * has already shipped a struct layout that was right on x86-64 and silently
 * corrupted every event on aarch64 (lightbug_http/c/epoll.mojo:48-70).
 */

#include <stddef.h>
#include <sqlite3.h>

#define CHECK(what, expr, want) \
    _Static_assert((expr) == (want), what " changed: " #expr " != " #want)

/* --- Pointer width. Everything below assumes LP64. --------------------- */
CHECK("pointer width", sizeof(void *), 8);

/* --- sqlite3_module: int iVersion + 24 function pointers ---------------
 * vtab.mojo indexes this as 8-byte words, which requires iVersion to be
 * padded out to 8 before the first callback. M_* names are vtab.mojo's.
 */
CHECK("M_VERSION", offsetof(sqlite3_module, iVersion), 0 * 8);
CHECK("M_CREATE", offsetof(sqlite3_module, xCreate), 1 * 8);
CHECK("M_CONNECT", offsetof(sqlite3_module, xConnect), 2 * 8);
CHECK("M_BESTINDEX", offsetof(sqlite3_module, xBestIndex), 3 * 8);
CHECK("M_DISCONNECT", offsetof(sqlite3_module, xDisconnect), 4 * 8);
CHECK("M_DESTROY", offsetof(sqlite3_module, xDestroy), 5 * 8);
CHECK("M_OPEN", offsetof(sqlite3_module, xOpen), 6 * 8);
CHECK("M_CLOSE", offsetof(sqlite3_module, xClose), 7 * 8);
CHECK("M_FILTER", offsetof(sqlite3_module, xFilter), 8 * 8);
CHECK("M_NEXT", offsetof(sqlite3_module, xNext), 9 * 8);
CHECK("M_EOF", offsetof(sqlite3_module, xEof), 10 * 8);
CHECK("M_COLUMN", offsetof(sqlite3_module, xColumn), 11 * 8);
CHECK("M_ROWID", offsetof(sqlite3_module, xRowid), 12 * 8);

/* M_SLOTS = 25 words must cover the whole struct as this header declares it.
 *
 * Note this assertion is stricter than vtab.mojo actually needs. What SQLite
 * reads is bounded by the iVersion we write, not by the header we compiled
 * against: at iVersion=1 it reads through xRename (slot 19), so the 25-word
 * buffer stays safe even against a future SQLite that appends fields. That
 * matters because this file is checked against whichever sqlite3.h is
 * installed here, which is not the one macOS ships.
 */
_Static_assert(sizeof(sqlite3_module) <= 25 * 8,
               "M_SLOTS=25 no longer covers sqlite3_module");

/* --- sqlite3_vtab: xConnect allocates 4 zeroed words for this ---------- */
_Static_assert(sizeof(sqlite3_vtab) <= 4 * 8,
               "xConnect's 32-byte allocation no longer covers sqlite3_vtab");

/* --- sqlite3_vtab_cursor: vtab.mojo appends its own fields after it ----
 * C_VTAB is word 0; C_DATA/C_COUNT/C_INDEX are words 1..3, which is only
 * safe while the base struct is exactly one word.
 */
CHECK("C_VTAB", offsetof(sqlite3_vtab_cursor, pVtab), 0 * 8);
CHECK("cursor base size", sizeof(sqlite3_vtab_cursor), 1 * 8);

/* --- sqlite3_index_info, indexed as words by _x_best_index ------------- */
CHECK("II_NCONSTRAINT", offsetof(sqlite3_index_info, nConstraint), 0 * 8);
CHECK("II_ACONSTRAINT", offsetof(sqlite3_index_info, aConstraint), 1 * 8);
CHECK("II_AUSAGE", offsetof(sqlite3_index_info, aConstraintUsage), 4 * 8);
CHECK("II_IDXNUM", offsetof(sqlite3_index_info, idxNum), 5 * 8);
CHECK("II_COST", offsetof(sqlite3_index_info, estimatedCost), 8 * 8);

/* --- the two inner arrays _x_best_index strides over ------------------- */
CHECK("CONSTRAINT_STRIDE",
      sizeof(struct sqlite3_index_constraint), 12);
CHECK("constraint iColumn",
      offsetof(struct sqlite3_index_constraint, iColumn), 0);
CHECK("constraint op",
      offsetof(struct sqlite3_index_constraint, op), 4);
CHECK("constraint usable",
      offsetof(struct sqlite3_index_constraint, usable), 5);

CHECK("USAGE_STRIDE",
      sizeof(struct sqlite3_index_constraint_usage), 8);
CHECK("usage argvIndex",
      offsetof(struct sqlite3_index_constraint_usage, argvIndex), 0);
CHECK("usage omit",
      offsetof(struct sqlite3_index_constraint_usage, omit), 4);

/* --- scalar widths the callback signatures depend on ------------------- */
CHECK("int width", sizeof(int), 4);
CHECK("sqlite3_int64 width", sizeof(sqlite3_int64), 8);
CHECK("double width", sizeof(double), 8);
