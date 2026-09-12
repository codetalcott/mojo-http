"""Connection strings: the defaults this package applies, and redaction.

Two jobs, both pure, both testable without a server.

**Defaults are merged, never appended.** libpq reads a URL's query string as
connection keywords, and a repeated keyword takes the LAST occurrence — so
appending `connect_timeout=5` to a URL that already sets it silently
overrides the caller. `with_defaults` parses what is there and adds only
what is missing, which is what lets `open` promise a statement timeout while
leaving an application free to choose its own.

**Redaction happens before a URL reaches anything that keeps it.** A
`DATABASE_URL` carries its password in the authority, and an error message is
the most widely copied string a server produces: into a log, an issue, a
paste to a colleague. libpq's own connection errors never echo the password;
neither may this package. `redact` handles both places one can hide — the
authority's `user:password@` and a `password=` keyword — and is applied by
every path that names a URL at all, including `--doctor`.
"""

from std.collections.span import Span


comptime DEFAULT_CONNECT_TIMEOUT = "5"
comptime DEFAULT_STATEMENT_TIMEOUT_MS = "5000"
"""A bound on a single statement, the twin of `m0-sqlite`'s busy timeout.

A pool thread blocked in a slow query is the shape of finding 2 in
docs/REAL_APP_VALIDATION.md — a handler that does not come back holds its
thread, and enough of them hold the pool. The bound belongs at the
connection, where every query inherits it, rather than at each call site,
where it would be forgotten. It surfaces as SQLSTATE 57014.
"""

comptime REDACTED = "***"


def _split_query(url: String) -> Tuple[String, String]:
    """(everything before the query string, the query string).

    The `?` that starts a query string cannot appear earlier in a valid
    connection URI: it is not legal in a scheme, a userinfo, a host or a
    path segment without encoding. A key/value conninfo (`host=x port=5432`)
    has no `?` at all and comes back whole as the head, which is correct —
    its keywords are space-separated and handled by the caller.
    """
    var b = url.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(ord("?")):
            return (
                String(unsafe_from_utf8=b[:i]),
                String(unsafe_from_utf8=b[i + 1 :]),
            )
    return (url, String(""))


def is_uri(url: String) -> Bool:
    """Whether this is a `postgres://` URI rather than a key/value conninfo.

    libpq accepts both. The difference matters here because the two hide a
    password in different places and spell their keywords differently.
    """
    return url.startswith("postgres://") or url.startswith("postgresql://")


def has_keyword(url: String, key: String) -> Bool:
    """Whether `key` is already set, in either conninfo spelling.

    Matched at a boundary — the start, or after a separator — so that
    looking for `dbname` does not find `fallback_application_name`, and
    looking for `password` does not find a `password` that is part of a
    longer word.
    """
    var hay = url.as_bytes()
    var needle = (key + "=").as_bytes()
    var n = len(needle)
    for i in range(len(hay) - n + 1):
        var matched = True
        for j in range(n):
            if hay[i + j] != needle[j]:
                matched = False
                break
        if not matched:
            continue
        if i == 0:
            return True
        var prev = hay[i - 1]
        if (
            prev == UInt8(ord("?"))
            or prev == UInt8(ord("&"))
            or prev == UInt8(ord(" "))
        ):
            return True
    return False


def with_defaults(url: String) raises -> String:
    """Add this package's connection defaults, keeping every one already set.

    What is added, and why each is a default rather than a caller's job:

    - `connect_timeout` — without it a connection to an unreachable host
      hangs for the OS's TCP timeout, which on a pool thread is that thread
      gone for minutes.
    - `client_encoding=UTF8` — makes the server's own guarantee do the work
      G14 does for request bytes: every text value is then valid UTF-8, so
      a `String` built from one holds String's invariant.
    - `application_name=m0serve` — so `pg_stat_activity` names this server
      rather than showing an anonymous connection beside the application's.
    - `options=-c statement_timeout=...` — see DEFAULT_STATEMENT_TIMEOUT_MS.

    A key/value conninfo (`host=x dbname=y`) is extended with the same
    keywords space-separated; a URI gets them as query parameters. Both
    spellings are libpq's, and mixing them is what a naive append would do.
    """
    var uri = is_uri(url)
    var parts = _split_query(url)
    # Where the keywords live: a URI's query string, or the whole conninfo.
    var scope = parts[1] if uri else url
    var out = url

    if not has_keyword(scope, "connect_timeout"):
        out += _sep(out, uri) + "connect_timeout=" + DEFAULT_CONNECT_TIMEOUT
    if not has_keyword(scope, "client_encoding"):
        out += _sep(out, uri) + "client_encoding=UTF8"
    if not has_keyword(scope, "application_name"):
        out += _sep(out, uri) + "application_name=m0serve"
    # `options` is one keyword whose VALUE is a command line, so an
    # application that sets its own keeps them entire: this is
    # all-or-nothing rather than merged inside the value, which is the
    # honest reading of a field libpq passes through verbatim.
    if not has_keyword(scope, "options"):
        out += _sep(out, uri) + "options=" + _options_value(
            "-c statement_timeout=" + DEFAULT_STATEMENT_TIMEOUT_MS, uri
        )
    return out


def _sep(so_far: String, uri: Bool) -> String:
    """The separator a further keyword needs, given what is written already.

    A URI's first keyword opens the query string with `?` and the rest join
    with `&`; a key/value conninfo separates with a space throughout.
    """
    if not uri:
        return String(" ")
    return String("&") if len(_split_query(so_far)[1].as_bytes()) > 0 else String("?")


def _options_value(value: String, uri: Bool) -> String:
    """`options`' value, percent-encoded where the spelling requires it.

    In a URI the value is a query parameter, so the spaces and `=` inside
    the command line have to be encoded or libpq reads the `=` as the end
    of the keyword. In a key/value conninfo the value is quoted instead,
    which is libpq's own escape for a value containing spaces.
    """
    if not uri:
        return "'" + value + "'"
    var out = List[UInt8](capacity=len(value.as_bytes()) * 3)
    for ch in value.as_bytes():
        if ch == UInt8(ord(" ")):
            out.append(UInt8(ord("%")))
            out.append(UInt8(ord("2")))
            out.append(UInt8(ord("0")))
        elif ch == UInt8(ord("=")):
            out.append(UInt8(ord("%")))
            out.append(UInt8(ord("3")))
            out.append(UInt8(ord("D")))
        else:
            out.append(ch)
    return String(unsafe_from_utf8=Span(out))


def read_only(url: String) raises -> String:
    """`with_defaults`, plus a transaction default that refuses every write.

    The belt to the role's braces: a read-only ROLE is the guard that
    matters, and this is what makes a mistake in the role's grants show up
    as an error on the connection that should not be writing rather than as
    a write that succeeds. SQLSTATE 25006.

    Folded into the same `options` value as the statement timeout, because
    libpq takes one `options` keyword and a second would replace the first.
    """
    if has_keyword(url, "options"):
        # The caller owns the whole field; adding a second would silently
        # drop theirs. Say so rather than half-applying the promise.
        raise Error(
            "open_readonly cannot add its read-only default to a connection"
            " string that already sets `options` — put `-c"
            " default_transaction_read_only=on` in yours, or use `open`"
        )
    var uri = is_uri(url)
    var base = with_defaults(url)
    # `with_defaults` just wrote the `options` keyword this appends to, so
    # the two commands travel as one value, which is what libpq takes.
    var extra = " -c default_transaction_read_only=on"
    if not uri:
        # The value it wrote is quoted; extend inside the quotes.
        var inside = String(unsafe_from_utf8=base.as_bytes()[: len(base.as_bytes()) - 1])
        return inside + extra + "'"
    return base + _options_value(extra, uri)


def redact(url: String) -> String:
    """A connection string safe to log: no password, everything else kept.

    Both hiding places:

    - the URI authority, `postgres://user:secret@host/db` — everything
      between the first `:` after the scheme's `//` and the `@`;
    - a `password=` keyword, in a query string or a key/value conninfo.

    Deliberately total rather than raising: this is called on the error
    path, and a redactor that can fail is a redactor that eventually does
    not run. Anything it cannot parse comes back fully masked, because a
    string this function does not understand is exactly the one not to
    print.
    """
    var b = url.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    var i = 0

    # The authority, if this is a URI: scan to the `@` that ends it, and
    # mask from the first `:` after the scheme.
    var scheme_end = -1
    for k in range(n - 2):
        if b[k] == UInt8(ord(":")) and b[k + 1] == UInt8(ord("/")) and b[k + 2] == UInt8(ord("/")):
            scheme_end = k + 3
            break
    if scheme_end >= 0:
        var at = -1
        for k in range(scheme_end, n):
            if b[k] == UInt8(ord("@")):
                at = k
                break
            if b[k] == UInt8(ord("/")) or b[k] == UInt8(ord("?")):
                break
        if at >= 0:
            var colon = -1
            for k in range(scheme_end, at):
                if b[k] == UInt8(ord(":")):
                    colon = k
                    break
            if colon >= 0:
                for k in range(colon + 1):
                    out.append(b[k])
                for ch in REDACTED.as_bytes():
                    out.append(ch)
                i = at
    while i < n:
        out.append(b[i])
        i += 1

    var once = String(unsafe_from_utf8=Span(out))
    return _mask_keyword(once, "password")


def _mask_keyword(url: String, key: String) -> String:
    """Replace every `key=value` value with the mask, at a boundary.

    Values end at the conninfo separator: `&` in a URI's query string, a
    space in a key/value string. Both are checked, because this runs over
    whichever spelling arrived.
    """
    var b = url.as_bytes()
    var needle = (key + "=").as_bytes()
    var n = len(b)
    var m = len(needle)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var matched = i + m <= n
        if matched:
            for j in range(m):
                if b[i + j] != needle[j]:
                    matched = False
                    break
        if matched and i > 0:
            var prev = b[i - 1]
            matched = (
                prev == UInt8(ord("?"))
                or prev == UInt8(ord("&"))
                or prev == UInt8(ord(" "))
            )
        if not matched:
            out.append(b[i])
            i += 1
            continue
        for j in range(m):
            out.append(needle[j])
        for ch in REDACTED.as_bytes():
            out.append(ch)
        i += m
        while i < n and b[i] != UInt8(ord("&")) and b[i] != UInt8(ord(" ")):
            i += 1
    return String(unsafe_from_utf8=Span(out))
