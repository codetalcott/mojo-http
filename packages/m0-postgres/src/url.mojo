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
paste to a colleague. `redact` handles every place one can hide — the
authority's `user:password@` and the secret keywords, in both spellings — and
masks whole any string it cannot parse. It is applied by every path that
names a URL at all. libpq's own connection errors never echo a password they
PARSED, but they quote pieces of a string they could not parse, so the error
text beside a URL goes through `redact_message`, which withholds it in exactly
that case.
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

comptime DEFAULT_KEEPALIVES_IDLE_S = "30"
comptime DEFAULT_KEEPALIVES_INTERVAL_S = "10"
comptime DEFAULT_KEEPALIVES_COUNT = "3"
comptime DEFAULT_TCP_USER_TIMEOUT_MS = "60000"
"""TCP keepalives, and a bound on unacknowledged data: a dead peer in ~a minute.

Thirty idle seconds, then a probe every ten, three unanswered probes; and
sixty seconds for data the peer never acknowledges. Both halves matter.
Keepalives are what notice a connection that went quiet and then went away
— a NAT or proxy forgetting an idle `LISTEN` connection. libpq already
turns `SO_KEEPALIVE` on, but with the OS's timings: measured on macOS
through the bare constructor, 7200 s idle, a probe every 75 s, 8 probes —
over two hours of a listener parked in `poll` on a socket that is gone,
and Linux's defaults are the same two hours. With these defaults the same
connection reads 30, 10 and 3. `tcp_user_timeout`
bounds the other shape: a query written into a half-open connection, which
otherwise blocks in `recv` with no client-side bound at all (the statement
timeout is enforced by the SERVER, which is the side that is gone).

All four keywords predate libpq 12, this package's floor (`tcp_user_timeout`
arrived in 12 itself). libpq ignores them on a Unix socket, and
`tcp_user_timeout` where the platform has no `TCP_USER_TIMEOUT` (macOS),
so none of them can fail a connection.
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
    longer word. The separators are a URI query's `?` and `&`, and ANY
    whitespace, because libpq's `conninfo_parse` separates key/value tokens
    on `isspace` — the same set `_is_space` recognises, so a
    tab-separated `host=db\tkeepalives=0` (a heredoc `DATABASE_URL`, say) is
    detected. Checking only a literal space missed it, and `with_defaults`
    then appended a second `keepalives=1` that libpq, taking the last
    occurrence, honoured over the caller's own.
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
            or _is_space(prev)
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
    - `keepalives=1` with `keepalives_idle`, `keepalives_interval`,
      `keepalives_count` and `tcp_user_timeout` — see
      DEFAULT_TCP_USER_TIMEOUT_MS. Each is merged on its own, so a caller
      who sets `keepalives=0` keeps it and the tuning beside it is inert.

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
    if not has_keyword(scope, "keepalives"):
        out += _sep(out, uri) + "keepalives=1"
    if not has_keyword(scope, "keepalives_idle"):
        out += _sep(out, uri) + "keepalives_idle=" + DEFAULT_KEEPALIVES_IDLE_S
    if not has_keyword(scope, "keepalives_interval"):
        out += (
            _sep(out, uri) + "keepalives_interval="
            + DEFAULT_KEEPALIVES_INTERVAL_S
        )
    if not has_keyword(scope, "keepalives_count"):
        out += _sep(out, uri) + "keepalives_count=" + DEFAULT_KEEPALIVES_COUNT
    if not has_keyword(scope, "tcp_user_timeout"):
        out += (
            _sep(out, uri) + "tcp_user_timeout=" + DEFAULT_TCP_USER_TIMEOUT_MS
        )
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
    """A connection string safe to log: no secret, everything else kept.

    Every place one can hide:

    - the URI authority, `postgres://user:secret@host/db` — everything
      between the first `:` of the userinfo and the LAST `@` of the
      authority, so a password carrying `:` or `@` is masked whole;
    - a secret keyword — `password`, `sslpassword`, `oauth_client_secret` —
      in a URI's query string or a key/value conninfo, where the key/value
      form is read the way libpq reads it: spaces allowed around `=`, a
      value single-quoted with backslash escapes, or unquoted to the next
      space.

    Deliberately total rather than raising: this is called on the error
    path, and a redactor that can fail is a redactor that eventually does
    not run. **Anything it cannot parse comes back fully masked** — keeping
    only the `postgres://` spelling, if it had one — because a string this
    function does not understand is exactly the one not to print. That
    includes every string libpq itself would refuse to parse: a keyword it
    does not know, a query parameter with no `=`, an unterminated quote, and
    any `@` after the authority. The last is the shape an unencoded `/` or
    `?` in a password makes — `postgres://u:ab/cd@host/db` ends its
    authority at the `/`, and a scan that stopped there printed the whole
    password — and it over-masks a query value that legitimately carries an
    `@`, which is the safe direction to be wrong in.
    """
    if len(url.as_bytes()) == 0:
        return url
    var secrets = List[String]()
    var parsed = _parse_and_mask(url, secrets)
    if parsed:
        return parsed.value()
    return _fully_masked(url)


def redact_message(message: String, url: String) -> String:
    """The error text libpq wrote about `url`, made safe to print beside it.

    libpq never echoes a password it PARSED, but a string it could not
    parse is quoted back in pieces: `postgres://u:ab/cd@127.0.0.1:1/db`
    answers `invalid integer value "ab" for connection option "port"`,
    which is half the password, and the listener printed it on every retry.
    So when `redact` could not parse the string the message is withheld
    and replaced by what to check; when it could, the message is kept —
    it is the diagnosis — with any secret value that appears in it masked.
    """
    var secrets = List[String]()
    var parsed = _parse_and_mask(url, secrets)
    if not parsed:
        return String(
            "libpq's message is withheld because the connection string could"
            " not be parsed, and libpq quotes what it cannot parse — check"
            " that `/`, `?`, `@` and `:` in a password are percent-encoded"
            " (%2F, %3F, %40, %3A)"
        )
    var out = message
    for secret in secrets:
        if len(secret.as_bytes()) > 0:
            out = _replace_all(out, secret, REDACTED)
    return out


def _fully_masked(url: String) -> String:
    """The mask for a string `redact` could not parse: its spelling, no more."""
    if url.startswith("postgresql://"):
        return String("postgresql://") + REDACTED
    if url.startswith("postgres://"):
        return String("postgres://") + REDACTED
    return String(REDACTED)


def _parse_and_mask(url: String, mut secrets: List[String]) -> Optional[String]:
    """The masked string, or None if libpq's grammar does not describe it.

    Every secret value found is appended to `secrets`, for `redact_message`.
    """
    if is_uri(url):
        return _mask_uri(url, secrets)
    return _mask_keyvalue(url, secrets)


def is_secret_keyword(key: String) -> Bool:
    """Whether a libpq keyword's value is a credential.

    `password` is the obvious one; `sslpassword` unlocks a client key, and
    `oauth_client_secret` is libpq 18's. Each is masked wherever it appears.
    """
    return (
        key == "password"
        or key == "sslpassword"
        or key == "oauth_client_secret"
    )


def is_libpq_keyword(key: String) -> Bool:
    """Whether libpq 12 through 18 accepts `key` as a connection keyword.

    A closed list, and it can only err towards masking: a keyword a newer
    libpq added makes a string this function treats as unparseable, so it
    comes back fully masked rather than half-printed. Case-sensitive, as
    libpq's own lookup is. `ssl` is the URI-only alias libpq rewrites to
    `sslmode=require`.
    """
    for known in _libpq_keywords():
        if known == key:
            return True
    return False


def _libpq_keywords() -> List[String]:
    """`PQconninfoOptions`' names, from libpq 12 through 18."""
    return [
        "host",
        "hostaddr",
        "port",
        "dbname",
        "user",
        "password",
        "passfile",
        "require_auth",
        "channel_binding",
        "connect_timeout",
        "client_encoding",
        "options",
        "application_name",
        "fallback_application_name",
        "keepalives",
        "keepalives_idle",
        "keepalives_interval",
        "keepalives_count",
        "tcp_user_timeout",
        "replication",
        "gssencmode",
        "sslmode",
        "sslnegotiation",
        "sslcompression",
        "sslcert",
        "sslkey",
        "sslkeylogfile",
        "sslpassword",
        "sslcertmode",
        "sslrootcert",
        "sslcrl",
        "sslcrldir",
        "sslsni",
        "requirepeer",
        "requiressl",
        "ssl_min_protocol_version",
        "ssl_max_protocol_version",
        "min_protocol_version",
        "max_protocol_version",
        "krbsrvname",
        "gsslib",
        "gssdelegation",
        "service",
        "target_session_attrs",
        "load_balance_hosts",
        "oauth_issuer",
        "oauth_client_id",
        "oauth_client_secret",
        "oauth_scope",
        "ssl",
    ]


def _is_space(b: UInt8) -> Bool:
    """C's `isspace` over ASCII, which is what libpq's conninfo parser uses."""
    return (
        b == UInt8(ord(" "))
        or b == UInt8(ord("\t"))
        or b == UInt8(ord("\n"))
        or b == UInt8(ord("\r"))
        or b == UInt8(0x0B)
        or b == UInt8(0x0C)
    )


def _text(b: Span[UInt8, _], start: Int, end: Int) -> String:
    """Bytes `[start, end)` as a String, by byte span — never `[byte=a:b]`.

    A connection string is operator input and may not be UTF-8 where it is
    cut (G14's rule, for the same reason).
    """
    return String(unsafe_from_utf8=b[start:end])


def _append(mut out: List[UInt8], b: Span[UInt8, _], start: Int, end: Int):
    for k in range(start, end):
        out.append(b[k])


def _append_mask(mut out: List[UInt8]):
    for ch in REDACTED.as_bytes():
        out.append(ch)


def _mask_uri(url: String, mut secrets: List[String]) -> Optional[String]:
    """`postgres://[user[:password]@]hosts[/dbname][?key=value&...]`."""
    var b = url.as_bytes()
    var n = len(b)
    var start = 0
    for k in range(n - 2):
        if (
            b[k] == UInt8(ord(":"))
            and b[k + 1] == UInt8(ord("/"))
            and b[k + 2] == UInt8(ord("/"))
        ):
            start = k + 3
            break
    var auth_end = n
    for k in range(start, n):
        if b[k] == UInt8(ord("/")) or b[k] == UInt8(ord("?")):
            auth_end = k
            break
    # An `@` past the authority is a userinfo that a `/` or `?` in the
    # password cut short — or something this cannot tell apart from one.
    for k in range(auth_end, n):
        if b[k] == UInt8(ord("@")):
            return None

    var out = List[UInt8](capacity=n)
    _append(out, b, 0, start)
    var at = -1
    for k in range(start, auth_end):
        if b[k] == UInt8(ord("@")):
            at = k
    var hosts_start = start
    if at >= 0:
        var colon = -1
        for k in range(start, at):
            if b[k] == UInt8(ord(":")):
                colon = k
                break
        if colon >= 0:
            _append(out, b, start, colon + 1)
            _append_mask(out)
            secrets.append(_text(b, colon + 1, at))
        else:
            _append(out, b, start, at)
        out.append(UInt8(ord("@")))
        hosts_start = at + 1
    if not _valid_hosts(b, hosts_start, auth_end):
        return None
    _append(out, b, hosts_start, auth_end)

    var q = n
    for k in range(auth_end, n):
        if b[k] == UInt8(ord("?")):
            q = k
            break
    _append(out, b, auth_end, q)
    if q < n:
        out.append(UInt8(ord("?")))
        if not _mask_query(b, q + 1, n, out, secrets):
            return None
    return String(unsafe_from_utf8=Span(out))


def _valid_hosts(b: Span[UInt8, _], start: Int, end: Int) -> Bool:
    """A comma-separated host list, each `host`, `host:port` or `[v6]:port`.

    A port is digits. What fails here is typically a password's tail: in
    `postgres://u:ab/cd@host` the authority is `u:ab`, whose "port" is `ab`.
    """
    var i = start
    while i <= end:
        var entry_end = end
        for k in range(i, end):
            if b[k] == UInt8(ord(",")):
                entry_end = k
                break
        var j = i
        if j < entry_end and b[j] == UInt8(ord("[")):
            var close = -1
            for k in range(j, entry_end):
                if b[k] == UInt8(ord("]")):
                    close = k
                    break
            if close < 0:
                return False
            j = close + 1
        else:
            while j < entry_end and b[j] != UInt8(ord(":")):
                if (
                    b[j] == UInt8(ord("@"))
                    or b[j] == UInt8(ord("["))
                    or b[j] == UInt8(ord("]"))
                    or _is_space(b[j])
                ):
                    return False
                j += 1
        if j < entry_end:
            if b[j] != UInt8(ord(":")) or j + 1 == entry_end:
                return False
            for k in range(j + 1, entry_end):
                if b[k] < UInt8(ord("0")) or b[k] > UInt8(ord("9")):
                    return False
        i = entry_end + 1
    return True


def _mask_query(
    b: Span[UInt8, _],
    start: Int,
    end: Int,
    mut out: List[UInt8],
    mut secrets: List[String],
) -> Bool:
    """`key=value&...` into `out`, secrets masked. False if not libpq's shape."""
    if start == end:
        return True
    var i = start
    while i <= end:
        var seg_end = end
        for k in range(i, end):
            if b[k] == UInt8(ord("&")):
                seg_end = k
                break
        var eq = -1
        for k in range(i, seg_end):
            if b[k] == UInt8(ord("=")):
                eq = k
                break
        if eq <= i:
            return False
        var key = _text(b, i, eq)
        if not is_libpq_keyword(key):
            return False
        if i > start:
            out.append(UInt8(ord("&")))
        _append(out, b, i, eq + 1)
        if is_secret_keyword(key):
            _append_mask(out)
            secrets.append(_text(b, eq + 1, seg_end))
        else:
            _append(out, b, eq + 1, seg_end)
        i = seg_end + 1
    return True


def _mask_keyvalue(url: String, mut secrets: List[String]) -> Optional[String]:
    """`key = value ...`, read the way libpq's `conninfo_parse` reads it."""
    var b = url.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    var i = 0
    while True:
        while i < n and _is_space(b[i]):
            out.append(b[i])
            i += 1
        if i >= n:
            break
        var key_start = i
        while i < n and b[i] != UInt8(ord("=")) and not _is_space(b[i]):
            i += 1
        if i == key_start:
            return None
        var key = _text(b, key_start, i)
        if not is_libpq_keyword(key):
            return None
        _append(out, b, key_start, i)
        while i < n and _is_space(b[i]):
            out.append(b[i])
            i += 1
        if i >= n or b[i] != UInt8(ord("=")):
            return None
        out.append(b[i])
        i += 1
        while i < n and _is_space(b[i]):
            out.append(b[i])
            i += 1
        var value_start = i
        var inner_start: Int
        var inner_end: Int
        if i < n and b[i] == UInt8(ord("'")):
            i += 1
            inner_start = i
            var closed = False
            while i < n:
                if b[i] == UInt8(ord("\\")):
                    i += 2
                    continue
                if b[i] == UInt8(ord("'")):
                    closed = True
                    break
                i += 1
            if not closed:
                return None
            inner_end = i
            i += 1
        else:
            while i < n and not _is_space(b[i]):
                if b[i] == UInt8(ord("\\")):
                    i += 1
                i += 1
            if i > n:
                i = n
            inner_start = value_start
            inner_end = i
        if is_secret_keyword(key):
            _append_mask(out)
            secrets.append(_text(b, inner_start, inner_end))
        else:
            _append(out, b, value_start, i)
    return String(unsafe_from_utf8=Span(out))


def _replace_all(text: String, needle: String, replacement: String) -> String:
    """Every occurrence of `needle` replaced, by byte comparison."""
    var hay = text.as_bytes()
    var nb = needle.as_bytes()
    var h = len(hay)
    var m = len(nb)
    var out = List[UInt8](capacity=h)
    var i = 0
    while i < h:
        var matched = i + m <= h
        if matched:
            for j in range(m):
                if hay[i + j] != nb[j]:
                    matched = False
                    break
        if matched:
            for ch in replacement.as_bytes():
                out.append(ch)
            i += m
        else:
            out.append(hay[i])
            i += 1
    return String(unsafe_from_utf8=Span(out))
