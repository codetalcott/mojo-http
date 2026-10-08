from lightbug_http.io.bytes import byte


comptime http = "http"
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
