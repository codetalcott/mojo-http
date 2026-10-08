from lightbug_http.header import Header, HeaderKey, write_header


@fieldwise_init
struct RequestCookieJar(Copyable, Writable):
    var _inner: Dict[String, String]

    def __init__(out self):
        self._inner = Dict[String, String]()

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

        A value is kept as it was sent, double quotes included. RFC 6265
        §4.1.1 allows a cookie-value wrapped in DQUOTEs, and its successor
        draft (draft-ietf-httpbis-rfc6265bis-22 §4.1.1) says the quotes are
        not stripped: they are part of the value, stored and sent back
        with it. So a value an application set quoted comes back as it set
        it, the response jar writing values verbatim. (Go's `net/http`
        strips one pair and records that it did.) A WSGI or ASGI
        application parses the raw `Cookie` header itself and is not
        reached by this.
        """
        for chunk_ref in header_value.split(";"):
            var chunk = String(chunk_ref).strip()
            if chunk.byte_length() == 0:
                continue
            var eq = chunk.find("=")
            if eq < 0:
                continue
            var name = String(String(unsafe_from_utf8=chunk.as_bytes()[:eq]).strip())
            if name.byte_length() == 0:
                continue
            self._inner[name] = String(unsafe_from_utf8=chunk.as_bytes()[eq + 1 :])

    @always_inline
    def __contains__(self, key: String) -> Bool:
        return key in self._inner

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

    def write_to[T: Writer](self, mut writer: T):
        var header = self.to_header()
        if header:
            write_header(writer, header.value().key, header.value().value)

    def __eq__(self, other: RequestCookieJar) -> Bool:
        """Whether both jars hold the same names with the same values.

        Each name is looked up in the other jar. Every cookie of one jar
        was compared with every cookie of the other, so a jar of two or
        more was unequal even to its own copy (review record LF30).
        """
        if len(self._inner) != len(other._inner):
            return False

        for entry in self._inner.items():
            var theirs = other._inner.get(entry.key)
            if not theirs or theirs.value() != entry.value:
                return False
        return True
