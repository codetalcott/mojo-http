from std.collections import KeyElement
from std.hashlib.hash import Hasher

from lightbug_http.header import (
    HEADER_VALUE_ASCII,
    HEADER_VALUE_BREAKS,
    HeaderKey,
    encode_latin1_header_value,
    header_value_kind,
    span_breaks_header_line,
    write_header,
)
from lightbug_http.io.bytes import ByteWriter
from std.utils import Variant

from lightbug_http.cookie.cookie import Cookie


@fieldwise_init
struct ResponseCookieKey(ImplicitlyCopyable, KeyElement):
    var name: String
    var domain: String
    var path: String

    def __init__(
        out self,
        name: String,
        domain: Optional[String] = Optional[String](None),
        path: Optional[String] = Optional[String](None),
    ):
        self.name = name
        self.domain = domain.or_else("")
        self.path = path.or_else("/")

    def __ne__(self: Self, other: Self) -> Bool:
        return not (self == other)

    def __eq__(self: Self, other: Self) -> Bool:
        return self.name == other.name and self.domain == other.domain and self.path == other.path

    def __hash__[H: Hasher](self: Self, mut hasher: H):
        hasher.update((self.name + "~" + self.domain + "~" + self.path).as_bytes())


@fieldwise_init
struct ResponseCookieJar(Copyable, Sized, Writable):
    var _inner: Dict[ResponseCookieKey, Cookie]
    var raw: List[String]
    """Values written to the wire as `Set-Cookie` exactly as given, after
    the parsed cookies.

    A cookie this server builds itself is a `Cookie`. A cookie that arrives
    as a finished header line — from a WSGI or ASGI application, or an
    upstream — is not: the line IS the header, and the server's job is to
    transmit it. Parsing it into a `Cookie` and serialising that back was
    lossy in four ways, each measured against Django on a real project:
    `Expiration` is a stub whose `from_string` parsed nothing, so `expires=`
    vanished; `SameSite.from_string` matched only lowercase values, so
    `SameSite=Lax` vanished; `parts[0].split("=")` cut a value at its first
    `=`, which base64 padding puts at the end; and any attribute this struct
    does not know was dropped. Every Django session and CSRF cookie left
    without `expires` or `SameSite`. `add_raw` is the bypass.
    """

    def __init__(out self):
        self._inner = Dict[ResponseCookieKey, Cookie]()
        self.raw = List[String]()

    def __init__(out self, *cookies: Cookie):
        self._inner = Dict[ResponseCookieKey, Cookie]()
        self.raw = List[String]()
        for cookie in cookies:
            self.set_cookie(cookie)

    def __init__(out self, cookies: List[Cookie]):
        self._inner = Dict[ResponseCookieKey, Cookie]()
        self.raw = List[String]()
        for cookie in cookies:
            self.set_cookie(cookie)

    @always_inline
    def __setitem__(mut self, key: ResponseCookieKey, value: Cookie):
        self._inner[key] = value.copy()

    def __getitem__(self, key: ResponseCookieKey) raises -> Cookie:
        return self._inner[key].copy()

    def get(self, key: ResponseCookieKey) -> Optional[Cookie]:
        try:
            return self[key]
        except:
            return None

    @always_inline
    def __contains__(self, key: ResponseCookieKey) -> Bool:
        return key in self._inner

    @always_inline
    def __contains__(self, key: Cookie) -> Bool:
        return ResponseCookieKey(key.name, key.domain, key.path) in self

    def __str__(self) -> String:
        return String(self)

    def __len__(self) -> Int:
        return len(self._inner) + len(self.raw)

    @always_inline
    def set_cookie(mut self, cookie: Cookie):
        self[ResponseCookieKey(cookie.name, cookie.domain, cookie.path)] = cookie

    @always_inline
    def add_raw(mut self, line: String):
        """Queue one `Set-Cookie` value to be written verbatim — see `raw`."""
        self.raw.append(line)

    @always_inline
    def empty(self) -> Bool:
        return len(self) == 0

    # fn encode_to(mut self, mut writer: ByteWriter):
    #     for cookie in self._inner.values():
    #         var v = cookie[].build_header_value()
    #         write_header(writer, HeaderKey.SET_COOKIE, v)

    def write_to[T: Writer](self, mut writer: T):
        """One `Set-Cookie` line per cookie, the built ones first.

        A line holding CR, LF or NUL is DROPPED, as `Headers` drops such a
        header (SPEC G2): a cookie is a header value like any other, and a
        CRLF in one -- a `Cookie` a view built from request data, or a line
        an application handed `add_raw` -- would end the line and start a
        header of its own. The jar's other lines still go out.
        """
        for cookie in self._inner.values():
            var v = cookie.build_header_value()
            if not span_breaks_header_line(v.as_bytes()):
                write_header(writer, HeaderKey.SET_COOKIE, v)
        for line in self.raw:
            if not span_breaks_header_line(line.as_bytes()):
                write_header(writer, HeaderKey.SET_COOKIE, line)

    def write_latin1_to(self, mut writer: ByteWriter):
        """The jar's lines for the wire, each value in ISO-8859-1 as
        `Headers.write_latin1_to` writes every other header's (RFC 9110
        §5.5; PEP 3333 for a WSGI application's).

        The encoders used to write the jar through `write_to`, which puts a
        String's UTF-8 on the wire as it stands, so `Set-Cookie` was the one
        header whose bytes above 0x7F did not go out as the application
        gave them. The bridge stores every header as UTF-8 and leaves the
        transcode back to the writer: a WSGI application's `caf\\xe9` went
        out as `caf\\xc3\\xa9`, and an ASGI application's own bytes
        `caf\\xc3\\xa9` as `caf\\xc3\\x83\\xc2\\xa9`. A line `write_to` drops,
        this drops (SPEC G2).
        """
        for cookie in self._inner.values():
            _write_set_cookie_latin1(writer, cookie.build_header_value())
        for line in self.raw:
            _write_set_cookie_latin1(writer, line)


def _write_set_cookie_latin1(mut writer: ByteWriter, value: String):
    """One `Set-Cookie` line in latin-1, or nothing for a value holding CR,
    LF or NUL: `Headers.write_latin1_to`'s rules, for one header, the
    transcoded bytes asked again before they go out (SPEC G19)."""
    var bytes = value.as_bytes()
    var kind = header_value_kind(bytes)
    if kind == HEADER_VALUE_BREAKS:
        return
    if kind == HEADER_VALUE_ASCII:
        writer.write_header_line(HeaderKey.SET_COOKIE.as_bytes(), bytes)
    else:
        var latin1 = encode_latin1_header_value(value)
        if span_breaks_header_line(Span(latin1)):
            return
        writer.write_header_line(HeaderKey.SET_COOKIE.as_bytes(), Span(latin1))
