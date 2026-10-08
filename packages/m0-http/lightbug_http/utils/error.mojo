trait CustomError(Movable, Writable):
    """An error marker struct whose text is its comptime `message`.

    `__str__` is the trait's. `write_to` is each conformer's own, the one
    line `writer.write(Self.message)`: `Writable` already defaults it, to
    the struct's name and fields, and Mojo 1.1 refuses a second default
    from a refining trait. Measured by giving this trait a
    `def write_to(self, mut writer: Some[Writer])` default and compiling
    a conformer that declares none: "trait method requirement 'write_to'
    has conflicting default implementations in 'CustomError' and
    'Writable'; you must implement it manually". The generic
    `write_to[W: Writer, //]` form is refused too, as an "ambiguous use
    of 'write_to'". As the trait stands, a conformer that leaves
    `write_to` out compiles, and writes `ParseEmptyAddressError()` where
    its message belongs; `test_error_messages.mojo` reads every
    conformer's text back.
    """

    comptime message: String

    def __str__(self) -> String:
        """The `message`, as `String(self)` writes it."""
        return Self.message
