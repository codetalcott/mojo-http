from std.collections import KeyElement
from std.hashlib.hash import Hasher

from lightbug_http.header import HeaderKey, write_header
from lightbug_http.io.bytes import ByteWriter
from std.utils import Variant

from lightbug_http.cookie.cookie import Cookie, InvalidCookieError


@fieldwise_init
struct CookieParseError(Movable, Writable, TrivialRegisterPassable):
    """Error raised when a cookie header string fails to parse."""

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write("CookieParseError: Failed to parse cookie header string")

    def __str__(self) -> String:
        return String(self)


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

    def __moveinit__(out self: Self, deinit take: Self):
        self.name = take.name
        self.domain = take.domain
        self.path = take.path

    def __copyinit__(out self: Self, copy: Self):
        self.name = copy.name
        self.domain = copy.domain
        self.path = copy.path

    def __hash__[H: Hasher](self: Self, mut hasher: H):
        hasher.update(self.name + "~" + self.domain + "~" + self.path)


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
    `Expiration` is a stub whose `from_string` parses nothing, so `expires=`
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

    def from_headers(mut self, headers: List[String]) raises CookieParseError:
        for header in headers:
            try:
                self.set_cookie(Cookie.from_set_header(header))
            except:
                raise CookieParseError()

    # fn encode_to(mut self, mut writer: ByteWriter):
    #     for cookie in self._inner.values():
    #         var v = cookie[].build_header_value()
    #         write_header(writer, HeaderKey.SET_COOKIE, v)

    def write_to[T: Writer](self, mut writer: T):
        for cookie in self._inner.values():
            var v = cookie.build_header_value()
            write_header(writer, HeaderKey.SET_COOKIE, v)
        for line in self.raw:
            write_header(writer, HeaderKey.SET_COOKIE, line)
