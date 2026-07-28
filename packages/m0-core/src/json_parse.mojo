"""
JSON field extraction — typed extractors for string, int, number, and bool fields.

Extracts top-level values from JSON objects. The field locator walks the
object structurally (tracking string and depth state) so it will not match
field-name-like substrings appearing inside string values or nested objects.

`parse_json_field` decodes the standard JSON escape set (\\" \\\\ \\/ \\b \\f
\\n \\r \\t \\uXXXX, including surrogate pairs). Unknown escapes return the
empty string (the documented "not found" sentinel) so silently-wrong data is
never returned to callers.
"""


def _is_ws(b: UInt8) -> Bool:
    """Check if byte is JSON whitespace (space, tab, newline, carriage return)."""
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D


def _hex_digit(b: UInt8) -> Int:
    """Decode a single ASCII hex digit. Returns -1 if not a hex digit."""
    if b >= 0x30 and b <= 0x39:
        return Int(b) - 0x30
    if b >= 0x41 and b <= 0x46:
        return Int(b) - 0x41 + 10
    if b >= 0x61 and b <= 0x66:
        return Int(b) - 0x61 + 10
    return -1


def _append_utf8(mut out: List[UInt8], cp: Int) -> None:
    """Encode a Unicode code point as UTF-8 and append to `out`.

    Caller is responsible for ensuring `cp` is in [0, 0x10FFFF] and is not
    a surrogate. Surrogates are filtered upstream.
    """
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _skip_string(bytes: Span[UInt8, _], blen: Int, start: Int) -> Int:
    """Skip a JSON string starting at the opening quote. Returns the offset
    just past the closing quote, or -1 if the string is unterminated."""
    var i = start + 1
    while i < blen:
        var b = bytes[i]
        if b == 0x5C:  # backslash — skip the escape (including 6-byte \\uXXXX)
            i += 2
        elif b == 0x22:  # closing quote
            return i + 1
        else:
            i += 1
    return -1


def _skip_value(bytes: Span[UInt8, _], blen: Int, start: Int) -> Int:
    """Skip a JSON value (string, number, literal, object, or array). Returns
    the offset just past the value, or -1 on malformed input."""
    var i = start
    if i >= blen:
        return -1
    var b = bytes[i]
    if b == 0x22:  # string
        return _skip_string(bytes, blen, i)
    if b == 0x7B or b == 0x5B:  # '{' or '['
        var depth = 1
        i += 1
        while i < blen and depth > 0:
            var c = bytes[i]
            if c == 0x22:
                i = _skip_string(bytes, blen, i)
                if i == -1:
                    return -1
                continue
            if c == 0x7B or c == 0x5B:
                depth += 1
            elif c == 0x7D or c == 0x5D:
                depth -= 1
            i += 1
        if depth != 0:
            return -1
        return i
    # number, true, false, null — scan until a structural byte
    while i < blen:
        var c = bytes[i]
        if c == 0x2C or c == 0x7D or c == 0x5D or _is_ws(c):
            return i
        i += 1
    return i


def _find_value_start(body: String, field: String) -> Int:
    """Locate the byte offset of the value for top-level `field` in a JSON object.

    Structural scan: enters the outermost `{`, then at depth 1 reads each
    quoted key and compares it byte-wise against `field`. Skips matching
    values when the key does not match. Returns -1 if the field is not
    present at the top level (nested objects are not searched).
    """
    var bytes = body.as_bytes()
    var blen = body.byte_length()
    var field_bytes = field.as_bytes()
    var flen = field.byte_length()

    var i = 0
    while i < blen and _is_ws(bytes[i]):
        i += 1
    if i >= blen or bytes[i] != 0x7B:  # '{'
        return -1
    i += 1

    while i < blen:
        while i < blen and _is_ws(bytes[i]):
            i += 1
        if i >= blen:
            return -1
        if bytes[i] == 0x7D:  # '}'
            return -1
        if bytes[i] != 0x22:  # expected key opening quote
            return -1

        # Compare the key against `field` byte-by-byte, honoring escapes
        # only enough to keep the offsets aligned. (Field names with escapes
        # are rare and not supported; such keys simply won't match.)
        var key_start = i + 1
        var k = key_start
        var matches = True
        var field_idx = 0
        while k < blen:
            var kb = bytes[k]
            if kb == 0x5C:  # escape inside key — bail on match
                matches = False
                k += 2
                continue
            if kb == 0x22:  # closing quote
                break
            if matches:
                if field_idx >= flen or kb != field_bytes[field_idx]:
                    matches = False
                field_idx += 1
            k += 1
        if k >= blen or bytes[k] != 0x22:
            return -1
        if matches and field_idx != flen:
            matches = False

        i = k + 1
        while i < blen and _is_ws(bytes[i]):
            i += 1
        if i >= blen or bytes[i] != 0x3A:  # ':'
            return -1
        i += 1
        while i < blen and _is_ws(bytes[i]):
            i += 1
        if i >= blen:
            return -1

        if matches:
            return i

        # Skip the value, then expect ',' or '}'
        i = _skip_value(bytes, blen, i)
        if i == -1:
            return -1
        while i < blen and _is_ws(bytes[i]):
            i += 1
        if i >= blen:
            return -1
        if bytes[i] == 0x7D:
            return -1
        if bytes[i] != 0x2C:
            return -1
        i += 1

    return -1


def parse_json_field(body: String, field: String) -> String:
    """Extract a string value for top-level `field` from a JSON object.

    Handles the full JSON escape set: \\" \\\\ \\/ \\b \\f \\n \\r \\t \\uXXXX
    (with surrogate-pair support for non-BMP code points). Returns an empty
    string if the field is not found, the value is not a string, or the
    value contains an unknown/malformed escape sequence.
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return String("")
    var bytes = body.as_bytes()
    var blen = body.byte_length()
    if bytes[i] != 0x22:  # '"'
        return String("")
    i += 1  # skip opening quote

    var result = List[UInt8](capacity=64)
    while i < blen:
        var b = bytes[i]
        if b == 0x22:  # closing quote
            return String(unsafe_from_utf8=Span(unsafe_ptr=result.unsafe_ptr(), length=len(result)))
        if b == 0x5C:
            if i + 1 >= blen:
                return String("")
            var nxt = bytes[i + 1]
            if nxt == 0x22:
                result.append(0x22); i += 2
            elif nxt == 0x5C:
                result.append(0x5C); i += 2
            elif nxt == 0x2F:
                result.append(0x2F); i += 2
            elif nxt == 0x62:  # \b
                result.append(0x08); i += 2
            elif nxt == 0x66:  # \f
                result.append(0x0C); i += 2
            elif nxt == 0x6E:
                result.append(0x0A); i += 2
            elif nxt == 0x72:
                result.append(0x0D); i += 2
            elif nxt == 0x74:
                result.append(0x09); i += 2
            elif nxt == 0x75:  # \uXXXX
                if i + 6 > blen:
                    return String("")
                var d0 = _hex_digit(bytes[i + 2])
                var d1 = _hex_digit(bytes[i + 3])
                var d2 = _hex_digit(bytes[i + 4])
                var d3 = _hex_digit(bytes[i + 5])
                if d0 == -1 or d1 == -1 or d2 == -1 or d3 == -1:
                    return String("")
                var cp = (d0 << 12) | (d1 << 8) | (d2 << 4) | d3
                if cp >= 0xD800 and cp <= 0xDBFF:
                    # High surrogate — expect a following \uDCxx low surrogate.
                    if i + 12 > blen or bytes[i + 6] != 0x5C or bytes[i + 7] != 0x75:
                        return String("")
                    var e0 = _hex_digit(bytes[i + 8])
                    var e1 = _hex_digit(bytes[i + 9])
                    var e2 = _hex_digit(bytes[i + 10])
                    var e3 = _hex_digit(bytes[i + 11])
                    if e0 == -1 or e1 == -1 or e2 == -1 or e3 == -1:
                        return String("")
                    var low = (e0 << 12) | (e1 << 8) | (e2 << 4) | e3
                    if low < 0xDC00 or low > 0xDFFF:
                        return String("")
                    var combined = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                    _append_utf8(result, combined)
                    i += 12
                elif cp >= 0xDC00 and cp <= 0xDFFF:
                    return String("")  # lone low surrogate
                else:
                    _append_utf8(result, cp)
                    i += 6
            else:
                return String("")  # unknown escape — strict reject
        else:
            result.append(b)
            i += 1

    return String("")  # unterminated string


def parse_json_int(body: String, field: String) -> Optional[Int]:
    """Extract an integer value for top-level `field` from a JSON object.

    Returns `None` if the field is missing or not a valid integer.
    Overflow is not checked; callers should validate range when relevant.
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return None
    var bytes = body.as_bytes()
    var blen = body.byte_length()

    var negative = False
    if bytes[i] == 0x2D:  # '-'
        negative = True
        i += 1
        if i >= blen:
            return None

    if bytes[i] < 0x30 or bytes[i] > 0x39:
        return None

    var result = 0
    while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
        result = result * 10 + Int(bytes[i]) - 0x30
        i += 1

    if negative:
        return Optional[Int](-result)
    return Optional[Int](result)


def parse_json_number(body: String, field: String) -> Optional[Float64]:
    """Extract a numeric value (int or float) for top-level `field`.

    Returns `None` if the field is missing or not a valid JSON number.
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return None
    var bytes = body.as_bytes()
    var blen = body.byte_length()

    var start = i
    if i < blen and bytes[i] == 0x2D:
        i += 1
    while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
        i += 1
    if i < blen and bytes[i] == 0x2E:
        i += 1
        while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
            i += 1
    if i < blen and (bytes[i] == 0x65 or bytes[i] == 0x45):
        i += 1
        if i < blen and (bytes[i] == 0x2B or bytes[i] == 0x2D):
            i += 1
        while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
            i += 1

    if i == start:
        return None

    var num_str = String(body[byte=start:i])
    try:
        return Optional[Float64](Float64(num_str))
    except:
        return None


def parse_json_bool(body: String, field: String) -> Optional[Bool]:
    """Extract a boolean value for top-level `field`.

    Returns `None` if the field is missing or not a boolean literal.
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return None
    var bytes = body.as_bytes()
    var blen = body.byte_length()

    if i + 4 <= blen and bytes[i] == 0x74 and bytes[i + 1] == 0x72 and bytes[i + 2] == 0x75 and bytes[i + 3] == 0x65:
        return Optional[Bool](True)
    if i + 5 <= blen and bytes[i] == 0x66 and bytes[i + 1] == 0x61 and bytes[i + 2] == 0x6C and bytes[i + 3] == 0x73 and bytes[i + 4] == 0x65:
        return Optional[Bool](False)
    return None
