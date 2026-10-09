from std.collections.span import ContiguousSlice, _SpanIter
from std.memory import unsafe_memcpy


comptime Bytes = List[Byte]


comptime default_buffer_size = 4096
"""The default buffer size for reading and writing data."""


@always_inline
def byte[s: StringSpan]() -> Byte:
    comptime assert s.byte_length() == 1, "StringSpan must be of length 1 to convert to Byte."
    return s.as_bytes()[0]


struct ByteWriter(Writer):
    var _inner: Bytes

    def __init__(out self, capacity: Int = default_buffer_size):
        self._inner = Bytes(capacity=capacity)

    def __init__(out self, var inner: Bytes):
        """Initialize with an existing buffer (zero-alloc path for buffer reuse)."""
        self._inner = inner^

    @always_inline
    def write_bytes(mut self, bytes: Span[Byte, _]) -> None:
        """Writes the contents of `bytes` into the internal buffer.

        Args:
            bytes: The bytes to write.
        """
        self._inner.extend(bytes)

    def write_string(mut self, s: StringSpan) -> None:
        """Writes the contents of `s` into the internal buffer.

        Args:
            s: The string to write.
        """
        self._inner.extend(s.as_bytes())

    def write[*Ts: Writable](mut self, *args: *Ts) -> None:
        """Write data to the `Writer`.

        Parameters:
            Ts: The types of data to write.

        Args:
            args: The data to write.
        """

        comptime for i in range(args.__len__()):
            args[i].write_to(self)

    def write_header_line(mut self, name: Span[Byte, _], value: Span[Byte, _]):
        """`name: value\r\n` as one reservation and two copies.

        The `write(name, ": ", value, lineBreak)` form this replaces was
        four `extend`s per header -- each a capacity test, a possible
        reallocation and a `memcpy` call for two bytes -- and `List.extend`
        was 2.7 % of the loop thread with most of its calls from here.
        """
        var n = len(name)
        var v = len(value)
        var at = len(self._inner)
        var needed = at + n + v + 4
        if self._inner.capacity() < needed:
            var grown = self._inner.capacity() * 2
            self._inner.reserve(needed if needed > grown else grown)
        var dst = self._inner.unsafe_ptr()
        if n > 0:
            unsafe_memcpy(dest=dst.unsafe_offset(at), src=name.unsafe_ptr(), count=n)
        at += n
        dst.unsafe_offset(at)[] = 0x3A  # ':'
        dst.unsafe_offset(at + 1)[] = 0x20  # ' '
        at += 2
        if v > 0:
            unsafe_memcpy(dest=dst.unsafe_offset(at), src=value.unsafe_ptr(), count=v)
        at += v
        dst.unsafe_offset(at)[] = 0x0D
        dst.unsafe_offset(at + 1)[] = 0x0A
        self._inner._len = at + 2

    @always_inline
    def consuming_write(mut self, var b: Bytes):
        self._inner.extend(b^)

    def consume(deinit self) -> Bytes:
        return self._inner^


struct ByteView[origin: ImmOrigin](Copyable, Sized, Writable):
    """Convenience wrapper around a Span of Bytes."""

    var _inner: Span[Byte, Self.origin]

    @implicit
    def __init__(out self, b: Span[Byte, Self.origin]):
        self._inner = b

    def __len__(self) -> Int:
        return len(self._inner)

    def __getitem__(self, index: Int) -> Byte:
        return self._inner[index]

    def __getitem__(self, slc: ContiguousSlice) -> Self:
        return Self(self._inner[slc])

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(String(unsafe_from_utf8=self._inner))

    def __iter__(self) -> _SpanIter[Byte, Self.origin]:
        return self._inner.__iter__()

    def find(self, target: Byte) -> Int:
        """Finds the index of a byte in a byte span.

        Args:
            target: The byte to find.

        Returns:
            The index of the byte in the span, or -1 if not found.
        """
        for i in range(len(self)):
            if self[i] == target:
                return i

        return -1


@fieldwise_init
struct EndOfReaderError(Writable):
    var message: String

    def __init__(out self):
        self.message = "No more bytes to read."

    def write_to[W: Writer, //](self, mut writer: W) -> None:
        writer.write(self.message)


struct ByteReader[origin: ImmOrigin](Copyable, Sized):
    var _inner: Span[Byte, Self.origin]
    var read_pos: Int

    def __init__(out self, b: Span[Byte, Self.origin]):
        self._inner = b
        self.read_pos = 0

    def copy(self) -> Self:
        return ByteReader(self._inner[self.read_pos :])

    @always_inline
    def available(self) -> Bool:
        return self.read_pos < len(self._inner)

    def __len__(self) -> Int:
        return len(self._inner) - self.read_pos

    def remaining(self) -> Int:
        return len(self._inner) - self.read_pos

    def peek(self) raises EndOfReaderError -> Byte:
        if not self.available():
            raise EndOfReaderError()
        return self._inner[self.read_pos]

    def read_bytes(mut self) -> ByteView[Self.origin]:
        var count = len(self)
        var start = self.read_pos
        self.read_pos += count
        return self._inner[start : start + count]

    def read_until(mut self, char: Byte) -> ByteView[Self.origin]:
        var start = self.read_pos
        for i in range(start, len(self._inner)):
            if self._inner[i] == char:
                break
            self.increment()

        return self._inner[start : self.read_pos]

    @always_inline
    def increment(mut self, v: Int = 1):
        self.read_pos += v


def create_string_from_ptr[origin: ImmOrigin](ptr: Pointer[UInt8, origin], length: Int) -> String:
    """Create a String from a pointer and length.

    Copies raw bytes directly into the String. NOTE: may result in invalid UTF-8 for bytes >= 0x80.
    """
    if length <= 0:
        return String()

    # Copy raw bytes directly - this preserves the exact bytes from HTTP messages
    return String(unsafe_from_utf8=Span(unsafe_ptr=ptr, length=length))
