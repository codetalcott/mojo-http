"""
Minimal JSON field extraction — correct handling of escaped strings.

Extracts string values from simple JSON objects. Handles escaped quotes,
escaped backslashes, and whitespace between tokens.
"""


fn _is_ws(b: UInt8) -> Bool:
    """Check if byte is JSON whitespace (space, tab, newline, carriage return)."""
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D


fn parse_json_field(body: String, field: String) -> String:
    """Extract a string value for `field` from a JSON object body.

    Handles escaped quotes and backslashes inside values.
    Returns empty string if the field is not found.

    Example:
        parse_json_field('{"name":"Alice"}', "name")  # -> "Alice"
        parse_json_field('{"say":"he said \\"hi\\""}', "say")  # -> 'he said "hi"'
    """
    var needle = '"' + field + '"'
    var bytes = body.as_bytes()
    var blen = len(body)
    var pos = body.find(needle)
    if pos == -1:
        return String("")

    # Advance past the key and find the colon
    var i = pos + len(needle)
    # Skip whitespace
    while i < blen and _is_ws(bytes[i]):
        i += 1
    if i >= blen or bytes[i] != 0x3A:  # ':'
        return String("")
    i += 1
    # Skip whitespace after colon
    while i < blen and _is_ws(bytes[i]):
        i += 1
    if i >= blen or bytes[i] != 0x22:  # '"'
        return String("")
    i += 1  # skip opening quote

    # Parse the value, handling escapes
    var result = List[UInt8](capacity=64)
    while i < blen:
        var b = bytes[i]
        if b == 0x22:  # '"'
            # End of string
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
                # Unknown escape — preserve as-is
                result.append(b)
                result.append(next)
            i += 2
        else:
            result.append(b)
            i += 1

    # Unterminated string
    return String("")
