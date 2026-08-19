from lightbug_http.header import Header, HeaderKey, write_header
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
        self.add_pairs(cookie_header.value())

    def add_pairs(mut self, header_value: String):
        """Parse one `Cookie` field value — `a=1; b=2` — into the jar.

        Split on the *first* `=` only. A cookie-value is opaque and may
        contain `=`: base64 pads with it, so a Django `sessionid` routinely
        ends in one, and splitting on every `=` truncated the value to its
        first segment. Per RFC 6265 §5.4 the pairs are `; `-separated;
        surrounding whitespace is tolerated because a single `;` separator is
        common in the wild.

        A pair with no `=` at all is skipped rather than stored under an empty
        name — RFC 6265 §5.2 says to ignore it, and the empty-name entry it
        used to create could be clobbered by the next such pair.
        """
        for chunk_ref in header_value.split(";"):
            var chunk = String(chunk_ref).strip()
            if chunk.byte_length() == 0:
                continue
            var eq = chunk.find("=")
            if eq < 0:
                continue
            var name = String(String(chunk[byte=:eq]).strip())
            if name.byte_length() == 0:
                continue
            # TODO value must be "unquoted"
            self._inner[name] = String(chunk[byte=eq + 1 :])

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
        # Cookie names are case-sensitive (RFC 6265 §4.1.1), and `__contains__`
        # and `to_header` have always treated them that way. Lowercasing only
        # here meant a jar holding `sessionid` answered `get("sessionid")` but
        # a jar holding `sessionId` answered nothing to any spelling at all.
        return self._inner[key]

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
        return String(self)

    def __eq__(self, other: RequestCookieJar) -> Bool:
        if len(self._inner) != len(other._inner):
            return False

        for value in self._inner.items():
            for other_value in other._inner.items():
                if value.key != other_value.key or value.value != other_value.value:
                    return False
        return True
