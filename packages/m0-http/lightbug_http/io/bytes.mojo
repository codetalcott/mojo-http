from lightbug_http.connection import default_buffer_size
from lightbug_http.strings import BytesConstant
from std.collections.span import ContiguousSlice, _SpanIter


comptime Bytes = List[Byte]


@always_inline
def byte[s: StringSpan]() -> Byte:
    comptime assert s.byte_length() == 1, "StringSpan must be of length 1 to convert to Byte."
    return s.as_bytes()[0]


@always_inline
def is_newline(b: Byte) -> Bool:
    return b == BytesConstant.LF or b == BytesConstant.CR


@always_inline
def is_space(b: Byte) -> Bool:
    return b == BytesConstant.whitespace


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

    @always_inline
    def consuming_write(mut self, var b: Bytes):
        self._inner.extend(b^)

    def consume(deinit self) -> Bytes:
        return self._inner^


struct ByteView[origin: ImmOrigin](Boolable, Copyable, Equatable, Sized, Writable):
    """Convenience wrapper around a Span of Bytes."""

    var _inner: Span[Byte, Self.origin]

    @implicit
    def __init__(out self, b: Span[Byte, Self.origin]):
        self._inner = b

    def __len__(self) -> Int:
        return len(self._inner)

    def __bool__(self) -> Bool:
        return Bool(self._inner)

    def __contains__(self, b: Byte) -> Bool:
        for i in range(len(self._inner)):
            if self._inner[i] == b:
                return True
        return False

    def __contains__(self, b: Span[Byte, _]) -> Bool:
        if len(b) > len(self._inner):
            return False

        for i in range(len(self._inner) - len(b) + 1):
            var found = True
            for j in range(len(b)):
                if self._inner[i + j] != b[j]:
                    found = False
                    break
            if found:
                return True
        return False

    def __getitem__(self, index: Int) -> Byte:
        return self._inner[index]

    def __getitem__(self, slc: ContiguousSlice) -> Self:
        return Self(self._inner[slc])

    def __str__(self) -> String:
        return String(unsafe_from_utf8=self._inner)

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(String(unsafe_from_utf8=self._inner))

    def __eq__(self, other: Self) -> Bool:
        # both empty
        if not self._inner and not other._inner:
            return True
        if len(self) != len(other):
            return False

        for i in range(len(self)):
            if self[i] != other[i]:
                return False
        return True

    def __eq__(self, other: Span[Byte, _]) -> Bool:
        # both empty
        if not self._inner and not other:
            return True
        if len(self) != len(other):
            return False

        for i in range(len(self)):
            if self[i] != other[i]:
                return False
        return True

    def __eq__(self, other: Bytes) -> Bool:
        # Check if lengths match
        if len(self) != len(other):
            return False

        # Compare each byte
        for i in range(len(self)):
            if self[i] != other[i]:
                return False
        return True

    def __ne__(self, other: Span[Byte, _]) -> Bool:
        return not self == other

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

    def as_bytes(self) -> Span[Byte, Self.origin]:
        return self._inner


@fieldwise_init
struct OutOfBoundsError(Writable):
    var message: String

    def __init__(out self):
        self.message = "Tried to read past the end of the ByteReader."

    def write_to[W: Writer, //](self, mut writer: W) -> None:
        writer.write(self.message)

    def __str__(self) -> String:
        return self.message.copy()


@fieldwise_init
struct EndOfReaderError(Writable):
    var message: String

    def __init__(out self):
        self.message = "No more bytes to read."

    def write_to[W: Writer, //](self, mut writer: W) -> None:
        writer.write(self.message)

    def __str__(self) -> String:
        return self.message.copy()


struct ByteReader[origin: ImmOrigin](Copyable, Sized):
    var _inner: Span[Byte, Self.origin]
    var read_pos: Int

    def __init__(out self, b: Span[Byte, Self.origin]):
        self._inner = b
        self.read_pos = 0

    def copy(self) -> Self:
        return ByteReader(self._inner[self.read_pos :])

    def as_bytes(self) -> Span[Byte, Self.origin]:
        return self._inner[self.read_pos :]

    def __contains__(self, b: Byte) -> Bool:
        for i in range(self.read_pos, len(self._inner)):
            if self._inner[i] == b:
                return True
        return False

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

    def read_bytes(mut self, n: Int) raises OutOfBoundsError -> ByteView[Self.origin]:
        if self.read_pos + n > len(self._inner):
            raise OutOfBoundsError()
        var count = n
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
    def read_word(mut self) -> ByteView[Self.origin]:
        return self.read_until(BytesConstant.whitespace)

    def read_line(mut self) -> ByteView[Self.origin]:
        var start = self.read_pos
        for i in range(start, len(self._inner)):
            if is_newline(self._inner[i]):
                break
            self.increment()

        # If we are at the end of the buffer, there is no newline to check for.
        var ret = self._inner[start : self.read_pos]
        if not self.available():
            return ret

        if self._inner[self.read_pos] == BytesConstant.CR:
            self.increment(2)
        else:
            self.increment()
        return ret

    @always_inline
    def skip_whitespace(mut self):
        for i in range(self.read_pos, len(self._inner)):
            if is_space(self._inner[i]):
                self.increment()
            else:
                break

    @always_inline
    def skip_carriage_return(mut self):
        for i in range(self.read_pos, len(self._inner)):
            if self._inner[i] == BytesConstant.CR:
                self.increment(2)
            else:
                break

    @always_inline
    def increment(mut self, v: Int = 1):
        self.read_pos += v

    @always_inline
    def consume(var self, bytes_len: Int = -1) -> Bytes:
        return Bytes(self^._inner[self.read_pos : self.read_pos + len(self) + 1])


def create_string_from_ptr[origin: ImmOrigin](ptr: Pointer[UInt8, origin], length: Int) -> String:
    """Create a String from a pointer and length.

    Copies raw bytes directly into the String. NOTE: may result in invalid UTF-8 for bytes >= 0x80.
    """
    if length <= 0:
        return String()

    # Copy raw bytes directly - this preserves the exact bytes from HTTP messages
    return String(unsafe_from_utf8=Span(unsafe_ptr=ptr, length=length))


def bufis(s: String, t: String) -> Bool:
    """Check if string s equals t."""
    return s == t
