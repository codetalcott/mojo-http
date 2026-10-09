from lightbug_http.io.bytes import byte


comptime strHttp11 = "HTTP/1.1"
comptime strHttp10 = "HTTP/1.0"

comptime CR = "\r"
comptime LF = "\n"
comptime lineBreak = "\r\n"

comptime whitespace = " "


struct BytesConstant:
    comptime whitespace = byte[whitespace]()
    comptime CR = byte[CR]()
    comptime LF = byte[LF]()
    comptime TAB = byte["\t"]()
    comptime COLON = byte[":"]()
    comptime SEMICOLON = byte[";"]()

    comptime ZERO = byte["0"]()
    comptime ONE = byte["1"]()
    comptime NINE = byte["9"]()
    comptime A_UPPER = byte["A"]()
    comptime A_LOWER = byte["a"]()
    comptime F_UPPER = byte["F"]()
    comptime F_LOWER = byte["f"]()
    comptime H = byte["H"]()
    comptime T = byte["T"]()
    comptime P = byte["P"]()
    comptime SLASH = byte["/"]()
    comptime DOT = byte["."]()


# Token character map - represents which characters are valid in tokens
# RFC 9110 §5.6.2: token = 1*tchar
# tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
#         "0"-"9" / "A"-"Z" / "^" / "_" / "`" / "a"-"z" / "|" / "~"
#
# The 77 tchars as two 64-bit words: bit `c & 63` of the word for `c >> 6`.
# One shift and one AND per byte, where the range-and-compare chain this
# replaces walked up to eighteen tests for a hyphen -- the byte every
# browser header name carries -- and was 4.2 % of the loop thread inside
# `scan_token`. Built once: for c in tchars, (lo if c < 64 else hi) gets
# bit (c & 63). `test_parsing.mojo` checks all 256 bytes against the RFC's
# list.
comptime TCHAR_LO: UInt64 = 0x03FF6CFA00000000
comptime TCHAR_HI: UInt64 = 0x57FFFFFFC7FFFFFE


@always_inline
def is_token_char(c: UInt8) -> Bool:
    """Check if character is a valid token character."""
    if c >= 0x80:
        return False
    var word = TCHAR_HI if c >= 0x40 else TCHAR_LO
    return ((word >> UInt64(c & 0x3F)) & 1) == 1


# RFC 9110 §5.6.1-§5.6.3: a field whose value is a list is split on `,`, each
# member trimmed of OWS (`*( SP / HTAB )`), and an empty member is not a
# member. These two are that walk, written once, for `Connection`,
# `Transfer-Encoding`, `If-None-Match`, `Vary` and `Allow`, and the trims
# beside them in `Accept` and `Content-Type`: indices in, indices out, so
# nothing is allocated and no `String` is made. A request's value may hold
# bytes that are not UTF-8, and a bound is never a codepoint boundary
# (SPEC G14).


@always_inline
def trim_ows(x: Span[UInt8, _], a: Int, b: Int) -> Tuple[Int, Int]:
    """The bounds of `x[a:b]` without the SP and HTAB at either end."""
    var lo = a
    var hi = b
    while lo < hi and (x[lo] == 0x20 or x[lo] == 0x09):
        lo += 1
    while hi > lo and (x[hi - 1] == 0x20 or x[hi - 1] == 0x09):
        hi -= 1
    return (lo, hi)


@always_inline
def next_list_member(x: Span[UInt8, _], start: Int) -> Tuple[Int, Int, Int]:
    """The list member of `x` that begins at `start`: its bounds trimmed of
    OWS, and where the member after it begins, one past its comma.

    A walk runs `while start <= len(x)`, so an empty value, and a comma at
    either end, yield an empty member (`a == b`) for the caller to skip.
    The member is the last exactly when the third index is `len(x) + 1`.
    Asked as that equality, the parser's `Transfer-Encoding` walk compiles
    to the same instructions as the loop it replaced; asked as `> len(x)`,
    it did not.
    """
    var n = len(x)
    var stop = start
    while stop < n and x[stop] != 0x2C:  # ','
        stop += 1
    var member = trim_ows(x, start, stop)
    return (member[0], member[1], stop + 1)
