from lightbug_http.header import HeaderKey, write_header
from lightbug_http.io.bytes import ByteWriter
from lightbug_http.strings import lineBreak


@fieldwise_init
struct RequestCookieJar(Copyable, Writable):
    var _inner: Dict[String, String]

    def __init__(out self):
        self._inner = Dict[String, String]()

    def __init__(out self, *cookies: Cookie):
        self._inner = Dict[String, String]()
        for cookie in cookies:
            self._inner[cookie.name] = cookie.value

    def parse_cookies(mut self, headers: Headers) raises:
        var cookie_header = headers.get(HeaderKey.COOKIE)
        if not cookie_header:
            return None

        var cookie_strings = cookie_header.value().split("; ")

        for chunk in cookie_strings:
            var key = String("")
            var value = chunk
            if "=" in chunk:
                var key_value = chunk.split("=")
                key = String(key_value[0])
                value = key_value[1]

            # TODO value must be "unquoted"
            self._inner[key] = String(value)

    @always_inline
    def empty(self) -> Bool:
        return len(self._inner) == 0

    @always_inline
    def __contains__(self, key: String) -> Bool:
        return key in self._inner

    def __contains__(self, key: Cookie) -> Bool:
        return key.name in self

    @always_inline
    def __getitem__(self, key: String) raises -> String:
        return self._inner[key.lower()]

    def get(self, key: String) -> Optional[String]:
        try:
            return self[key]
        except:
            return Optional[String](None)

    def to_header(self) -> Optional[Header]:
        comptime equal = "="
        if len(self._inner) == 0:
            return None

        var header_value = List[String]()
        for cookie in self._inner.items():
            header_value.append(cookie.key + equal + cookie.value)
        return Header(HeaderKey.COOKIE, StaticString("; ").join(header_value))

    def encode_to(mut self, mut writer: ByteWriter):
        var header = self.to_header()
        if header:
            write_header(writer, header.value().key, header.value().value)

    def write_to[T: Writer](self, mut writer: T):
        var header = self.to_header()
        if header:
            write_header(writer, header.value().key, header.value().value)

    def __str__(self) -> String:
        return String.write(self)

    def __eq__(self, other: RequestCookieJar) -> Bool:
        if len(self._inner) != len(other._inner):
            return False

        for value in self._inner.items():
            for other_value in other._inner.items():
                if value.key != other_value.key or value.value != other_value.value:
                    return False
        return True
