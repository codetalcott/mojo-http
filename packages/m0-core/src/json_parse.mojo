"""
JSON field extraction — typed extractors for string, int, number, and bool fields.

Extracts values from simple JSON objects. Handles escaped strings,
numeric parsing, and boolean literals.
"""


def _is_ws(b: UInt8) -> Bool:
    """Check if byte is JSON whitespace (space, tab, newline, carriage return)."""
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D


def _find_value_start(body: String, field: String) -> Int:
    """Locate the byte offset of the value for `field` in a JSON object.

    Returns the index of the first non-whitespace byte after `"field":`,
    or -1 if the field is not found.
    """
    var needle = '"' + field + '"'
    var bytes = body.as_bytes()
    var blen = len(body)
    var pos = body.find(needle)
    if pos == -1:
        return -1
    var i = pos + len(needle)
    # Skip whitespace before colon
    while i < blen and _is_ws(bytes[i]):
        i += 1
    if i >= blen or bytes[i] != 0x3A:  # ':'
        return -1
    i += 1
    # Skip whitespace after colon
    while i < blen and _is_ws(bytes[i]):
        i += 1
    if i >= blen:
        return -1
    return i


def parse_json_field(body: String, field: String) -> String:
    """Extract a string value for `field` from a JSON object body.

    Handles escaped quotes and backslashes inside values.
    Returns empty string if the field is not found.

    Example:
        parse_json_field('{"name":"Alice"}', "name")  # -> "Alice"
        parse_json_field('{"say":"he said \\"hi\\""}', "say")  # -> 'he said "hi"'
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return String("")
    var bytes = body.as_bytes()
    var blen = len(body)
    if bytes[i] != 0x22:  # '"'
        return String("")
    i += 1  # skip opening quote

    # Parse the value, handling escapes
    var result = List[UInt8](capacity=64)
    while i < blen:
        var b = bytes[i]
        if b == 0x22:  # '"'
            return String(unsafe_from_utf8=Span(ptr=result.unsafe_ptr(), length=len(result)))
        elif b == 0x5C and i + 1 < blen:  # '\\'
            var next = bytes[i + 1]
            if next == 0x22:       # '\"'
                result.append(0x22)
            elif next == 0x5C:     # '\\\\'
                result.append(0x5C)
            elif next == 0x6E:     # '\\n'
                result.append(0x0A)
            elif next == 0x74:     # '\\t'
                result.append(0x09)
            elif next == 0x72:     # '\\r'
                result.append(0x0D)
            elif next == 0x2F:     # '\\/'
                result.append(0x2F)
            else:
                result.append(b)
                result.append(next)
            i += 2
        else:
            result.append(b)
            i += 1

    return String("")


def parse_json_int(body: String, field: String) -> Int:
    """Extract an integer value for `field` from a JSON object body.

    Returns -1 if the field is not found or the value is not a valid integer.

    Example:
        parse_json_int('{"count":42}', "count")  # -> 42
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return -1
    var bytes = body.as_bytes()
    var blen = len(body)

    # Handle optional negative sign
    var negative = False
    if bytes[i] == 0x2D:  # '-'
        negative = True
        i += 1
        if i >= blen:
            return -1

    # Must start with a digit
    if bytes[i] < 0x30 or bytes[i] > 0x39:  # '0'-'9'
        return -1

    var result = 0
    while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
        result = result * 10 + Int(bytes[i]) - 0x30
        i += 1

    if negative:
        return -result
    return result


def parse_json_number(body: String, field: String) -> Float64:
    """Extract a numeric value (int or float) for `field` from a JSON object body.

    Returns 0.0 if the field is not found or the value is not numeric.

    Example:
        parse_json_number('{"price":9.99}', "price")  # -> 9.99
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return 0.0
    var bytes = body.as_bytes()
    var blen = len(body)

    # Collect all numeric characters: digits, '.', '-', '+', 'e', 'E'
    var start = i
    if i < blen and bytes[i] == 0x2D:  # '-'
        i += 1
    # Integer part
    while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
        i += 1
    # Decimal part
    if i < blen and bytes[i] == 0x2E:  # '.'
        i += 1
        while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
            i += 1
    # Exponent part
    if i < blen and (bytes[i] == 0x65 or bytes[i] == 0x45):  # 'e' or 'E'
        i += 1
        if i < blen and (bytes[i] == 0x2B or bytes[i] == 0x2D):  # '+' or '-'
            i += 1
        while i < blen and bytes[i] >= 0x30 and bytes[i] <= 0x39:
            i += 1

    if i == start:
        return 0.0

    # Extract the numeric substring and parse
    var num_str = String(body[byte=start:i])
    try:
        return Float64(num_str)
    except:
        return 0.0


def parse_json_bool(body: String, field: String) -> Int:
    """Extract a boolean value for `field` from a JSON object body.

    Returns 1 for true, 0 for false, -1 if not found or not a boolean.

    Example:
        parse_json_bool('{"active":true}', "active")  # -> 1
    """
    var i = _find_value_start(body, field)
    if i == -1:
        return -1
    var bytes = body.as_bytes()
    var blen = len(body)

    # Check for 'true' (0x74 0x72 0x75 0x65)
    if i + 4 <= blen and bytes[i] == 0x74 and bytes[i + 1] == 0x72 and bytes[i + 2] == 0x75 and bytes[i + 3] == 0x65:
        return 1
    # Check for 'false' (0x66 0x61 0x6C 0x73 0x65)
    if i + 5 <= blen and bytes[i] == 0x66 and bytes[i + 1] == 0x61 and bytes[i + 2] == 0x6C and bytes[i + 3] == 0x73 and bytes[i + 4] == 0x65:
        return 0
    return -1
