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
 * Every M0_* below is vtab.mojo's constant of the same name, extracted from
 * that file and passed as -DM0_NAME=N by scripts/vtab_layout.py, which is
 * the only supported way to compile this file (the #error below is what
 * refuses a bare `cc`). It used to carry its own copies of the numbers, and
 * so asserted the header against this file rather than against vtab.mojo:
 * a wrong slot index in the Mojo source compiled, passed, and corrupted rows.
 * The script also holds the two files to one closed set of names — a
 * constant asserted here must exist there, and an offset added there must
 * be asserted here or declared Mojo-own — and `poe sabotage-vtab` moves
 * every constant in turn to prove the assertion can fail.
 *
 * `uv run poe verify-vtab-layout` runs it for the host, and `test-sqlite`
 * runs it before the Mojo tests. Native, not cross-compiled, because that is
 * what checks the sqlite3.h actually installed on the machine — the macOS SDK
 * copy on one CI runner and libsqlite3-dev's on the other, which between them
 * are the two headers this repo is ever built against.
 *
 * Before adding a target the CI matrix does not cover, sweep it by hand. This
 * needs a sysroot carrying sqlite3.h for each triple, which is why it is not
 * the gate (CC accepts a wrapper, so the script's defines still apply):
 *
 *   for t in x86_64-linux-gnu aarch64-linux-gnu arm64-apple-macos; do
 *     CC="clang -target $t" python3 scripts/vtab_layout.py && echo "$t OK"
 *   done
 *
 * Add a triple there rather than trusting that "64-bit is 64-bit": this repo
 * has already shipped a struct layout that was right on x86-64 and silently
 * corrupted every event on aarch64 (lightbug_http/c/epoll.mojo:48-70).
 */

#include <stddef.h>
#include <sqlite3.h>

#ifndef M0_M_VERSION
#error "compile through scripts/vtab_layout.py, which supplies vtab.mojo's constants as -DM0_*"
#endif

#define CHECK(what, expr, want) \
    _Static_assert((expr) == (want), what " changed: " #expr " != " #want)

/* --- Pointer width. Everything below assumes LP64. --------------------- */
CHECK("pointer width", sizeof(void *), 8);

/* --- sqlite3_module: int iVersion + 24 function pointers ---------------
 * vtab.mojo indexes this as 8-byte words, which requires iVersion to be
 * padded out to 8 before the first callback. M_* names are vtab.mojo's.
 */
CHECK("M_VERSION", offsetof(sqlite3_module, iVersion), M0_M_VERSION * 8);
CHECK("M_CONNECT", offsetof(sqlite3_module, xConnect), M0_M_CONNECT * 8);
CHECK("M_BESTINDEX", offsetof(sqlite3_module, xBestIndex), M0_M_BESTINDEX * 8);
CHECK("M_DISCONNECT", offsetof(sqlite3_module, xDisconnect), M0_M_DISCONNECT * 8);
CHECK("M_OPEN", offsetof(sqlite3_module, xOpen), M0_M_OPEN * 8);
CHECK("M_CLOSE", offsetof(sqlite3_module, xClose), M0_M_CLOSE * 8);
CHECK("M_FILTER", offsetof(sqlite3_module, xFilter), M0_M_FILTER * 8);
CHECK("M_NEXT", offsetof(sqlite3_module, xNext), M0_M_NEXT * 8);
CHECK("M_EOF", offsetof(sqlite3_module, xEof), M0_M_EOF * 8);
CHECK("M_COLUMN", offsetof(sqlite3_module, xColumn), M0_M_COLUMN * 8);
CHECK("M_ROWID", offsetof(sqlite3_module, xRowid), M0_M_ROWID * 8);
/* xCreate and xDestroy have no M_ constant: vtab.mojo never writes either
 * (a NULL xCreate is what makes the table eponymous-only), so these are
 * header facts with nothing on the Mojo side to compare against. */
CHECK("xCreate", offsetof(sqlite3_module, xCreate), 1 * 8);
CHECK("xDestroy", offsetof(sqlite3_module, xDestroy), 5 * 8);

/* M_SLOTS = 25 words must cover the whole struct as this header declares it.
 *
 * Note this assertion is stricter than vtab.mojo actually needs. What SQLite
 * reads is bounded by the iVersion we write, not by the header we compiled
 * against: at iVersion=1 it reads through xRename (slot 19), so the 25-word
 * buffer stays safe even against a future SQLite that appends fields. That
 * matters because this file is checked against whichever sqlite3.h is
 * installed here, which is not the one macOS ships.
 */
_Static_assert(sizeof(sqlite3_module) <= M0_M_SLOTS * 8,
               "M_SLOTS no longer covers sqlite3_module");

/* --- sqlite3_vtab: xConnect allocates V_WORDS zeroed words for this ---- */
_Static_assert(sizeof(sqlite3_vtab) <= M0_V_WORDS * 8,
               "xConnect's V_WORDS allocation no longer covers sqlite3_vtab");

/* --- sqlite3_vtab_cursor: vtab.mojo appends its own fields after it ----
 * C_VTAB is word 0 and C_DATA is the first word past the base struct; the
 * fields after C_DATA are Mojo's own and have no header counterpart.
 */
CHECK("C_VTAB", offsetof(sqlite3_vtab_cursor, pVtab), M0_C_VTAB * 8);
CHECK("C_DATA (cursor base size)", sizeof(sqlite3_vtab_cursor), M0_C_DATA * 8);

/* --- sqlite3_index_info, indexed as words by _x_best_index ------------- */
CHECK("II_NCONSTRAINT", offsetof(sqlite3_index_info, nConstraint), M0_II_NCONSTRAINT * 8);
CHECK("II_ACONSTRAINT", offsetof(sqlite3_index_info, aConstraint), M0_II_ACONSTRAINT * 8);
CHECK("II_AUSAGE", offsetof(sqlite3_index_info, aConstraintUsage), M0_II_AUSAGE * 8);
CHECK("II_IDXNUM", offsetof(sqlite3_index_info, idxNum), M0_II_IDXNUM * 8);
CHECK("II_COST", offsetof(sqlite3_index_info, estimatedCost), M0_II_COST * 8);

/* --- the two inner arrays _x_best_index strides over, in BYTES --------- */
CHECK("CONSTRAINT_STRIDE",
      sizeof(struct sqlite3_index_constraint), M0_CONSTRAINT_STRIDE);
CHECK("CONSTRAINT_ICOLUMN",
      offsetof(struct sqlite3_index_constraint, iColumn), M0_CONSTRAINT_ICOLUMN);
CHECK("CONSTRAINT_OP",
      offsetof(struct sqlite3_index_constraint, op), M0_CONSTRAINT_OP);
CHECK("CONSTRAINT_USABLE",
      offsetof(struct sqlite3_index_constraint, usable), M0_CONSTRAINT_USABLE);

CHECK("USAGE_STRIDE",
      sizeof(struct sqlite3_index_constraint_usage), M0_USAGE_STRIDE);
CHECK("USAGE_ARGVINDEX",
      offsetof(struct sqlite3_index_constraint_usage, argvIndex), M0_USAGE_ARGVINDEX);
CHECK("USAGE_OMIT",
      offsetof(struct sqlite3_index_constraint_usage, omit), M0_USAGE_OMIT);

/* --- the one header constant vtab.mojo copies by value ----------------- */
CHECK("SQLITE_INDEX_CONSTRAINT_EQ",
      SQLITE_INDEX_CONSTRAINT_EQ, M0_SQLITE_INDEX_CONSTRAINT_EQ);

/* --- scalar widths the callback signatures depend on ------------------- */
CHECK("int width", sizeof(int), 4);
CHECK("sqlite3_int64 width", sizeof(sqlite3_int64), 8);
CHECK("double width", sizeof(double), 8);
