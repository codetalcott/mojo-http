from std.collections import Optional
from std.collections._asan_annotations import __sanitizer_annotate_contiguous_container
from std.os import abort
from std.sys import size_of

from std.collections.span import Span
from std.memory import Pointer, unsafe_memcpy


# ===-----------------------------------------------------------------------===#
# List
# ===-----------------------------------------------------------------------===#


# @fieldwise_init
# struct _OwningListIter[
#     list_mutability: Bool,
#     //,
#     T: Movable,
#     list_origin: Origin[list_mutability],
#     forward: Bool = True,
# ](Copyable, Movable):
#     """Iterator for List.

#     Parameters:
#         list_mutability: Whether the reference to the list is mutable.
#         T: The type of the elements in the list.
#         list_origin: The origin of the List
#         forward: The iteration direction. `False` is backwards.
#     """

#     alias list_type = OwningList[T]

#     var index: Int
#     var src: Pointer[Self.list_type, list_origin]

#     fn __iter__(self) -> Self:
#         return self.copy()

#     fn __next__(
#         mut self,
#     ) -> Pointer[T, list_origin]:
#         @parameter
#         if forward:
#             self.index += 1
#             return Pointer(to=self.src[][self.index - 1])
#         else:
#             self.index -= 1
#             return Pointer(to=self.src[][self.index])

#     @always_inline
#     fn __has_next__(self) -> Bool:
#         return self.__len__() > 0

#     fn __len__(self) -> Int:
#         @parameter
#         if forward:
#             return len(self.src[]) - self.index
#         else:
#             return self.index


struct OwningList[T: Movable & Deinitable](Boolable, Movable, Sized):
    """The `List` type is a dynamically-allocated list.

    It supports pushing and popping from the back resizing the underlying
    storage as needed.  When it is deallocated, it frees its memory.

    Parameters:
        T: The type of the elements.
    """

    # Fields
    var data: Pointer[Self.T, MutUntrackedOrigin]
    """The underlying storage for the list."""
    var size: Int
    """The number of elements in the list."""
    var capacity: Int
    """The amount of elements that can fit in the list without resizing it."""

    def _annotate_new(self):
        __sanitizer_annotate_contiguous_container(
            beg=self.data.unsafe_bitcast[NoneType](),
            end=self.data.unsafe_offset(self.capacity).unsafe_bitcast[NoneType](),
            old_mid=self.data.unsafe_offset(self.capacity).unsafe_bitcast[NoneType](),
            new_mid=self.data.unsafe_offset(self.size).unsafe_bitcast[NoneType](),
        )

    def _annotate_delete(self):
        __sanitizer_annotate_contiguous_container(
            beg=self.data.unsafe_bitcast[NoneType](),
            end=self.data.unsafe_offset(self.capacity).unsafe_bitcast[NoneType](),
            old_mid=self.data.unsafe_offset(self.size).unsafe_bitcast[NoneType](),
            new_mid=self.data.unsafe_offset(self.capacity).unsafe_bitcast[NoneType](),
        )

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    def __init__(out self):
        """Constructs an empty list."""
        self.data = Pointer[Self.T, MutUntrackedOrigin](unsafe_from_address=0)
        self.size = 0
        self.capacity = 0

    def __init__(out self, *, capacity: Int):
        """Constructs a list with the given capacity.

        Args:
            capacity: The requested capacity of the list.
        """
        self.data = alloc[Self.T](count=capacity)
        self.size = 0
        self.capacity = capacity

    def __deinit__(deinit self):
        """Destroy all elements in the list and free its memory."""
        for i in range(self.size):
            self.data.unsafe_offset(i).unsafe_deinit_pointee()
        self.data.unsafe_free()

    # ===-------------------------------------------------------------------===#
    # Operator dunders
    # ===-------------------------------------------------------------------===#

    # __contains__ was removed rather than fixed: it was dead (nothing
    # in the repo asks an OwningList for membership), its `self:
    # OwningList[U, ...]` signature is invalid on the pinned toolchain,
    # and — like kevent_register before it — the parametric body was
    # only ever type-checked once a new instantiation context
    # elaborated it.

    # fn __iter__(ref self) -> _OwningListIter[T, origin_of(self)]:
    #     """Iterate over elements of the list, returning immutable references.

    #     Returns:
    #         An iterator of immutable references to the list elements.
    #     """
    #     return _OwningListIter(0, Pointer(to=self))

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    def __len__(self) -> Int:
        """Gets the number of elements in the list.

        Returns:
            The number of elements in the list.
        """
        return self.size

    def __bool__(self) -> Bool:
        """Checks whether the list has any elements or not.

        Returns:
            `False` if the list is empty, `True` if there is at least one element.
        """
        return len(self) > 0

    # __str__/write_to/__repr__ were removed with __contains__ (see
    # above): dead, and their `self: OwningList[U, ...]` signatures are
    # invalid on the pinned toolchain once anything elaborates them.

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    def bytecount(self) -> Int:
        """Gets the bytecount of the List.

        Returns:
            The bytecount of the List.
        """
        return len(self) * size_of[Self.T]()

    @no_inline
    def _realloc(mut self, new_capacity: Int):
        var new_data = alloc[Self.T](new_capacity)

        for i in range(len(self)):
            new_data.unsafe_offset(i).unsafe_write_move_from(self.data.unsafe_offset(i))

        if Int(self.data) != 0:
            self._annotate_delete()
            self.data.unsafe_free()
        self.data = new_data
        self.capacity = new_capacity
        self._annotate_new()

    def append(mut self, var value: Self.T):
        """Appends a value to this list.

        Args:
            value: The value to append.
        """
        if self.size >= self.capacity:
            self._realloc(max(1, self.capacity * 2))
        self.data.unsafe_offset(self.size).unsafe_write(value^)
        self.size += 1

    def insert(mut self, i: Int, var value: Self.T):
        """Inserts a value to the list at the given index.
        `a.insert(len(a), value)` is equivalent to `a.append(value)`.

        Args:
            i: The index for the value.
            value: The value to insert.
        """
        debug_assert(i <= self.size, "insert index out of range")

        var normalized_idx = i
        if i < 0:
            normalized_idx = max(0, len(self) + i)

        var earlier_idx = len(self)
        var later_idx = len(self) - 1
        self.append(value^)

        for _ in range(normalized_idx, len(self) - 1):
            var earlier_ptr = self.data.unsafe_offset(earlier_idx)
            var later_ptr = self.data.unsafe_offset(later_idx)

            var tmp = earlier_ptr.unsafe_take_pointee()
            earlier_ptr.unsafe_write_move_from(later_ptr)
            later_ptr.unsafe_write(tmp^)

            earlier_idx -= 1
            later_idx -= 1

    def extend(mut self, var other: OwningList[Self.T, ...]):
        """Extends this list by consuming the elements of `other`.

        Args:
            other: List whose elements will be added in order at the end of this list.
        """

        var final_size = len(self) + len(other)
        var other_original_size = len(other)

        self.reserve(final_size)

        # Defensively mark `other` as logically being empty, as we will be doing
        # consuming moves out of `other`, and so we want to avoid leaving `other`
        # in a partially valid state where some elements have been consumed
        # but are still part of the valid `size` of the list.
        #
        # That invalid intermediate state of `other` could potentially be
        # visible outside this function if a `__moveinit__()` constructor were
        # to throw (not currently possible AFAIK though) part way through the
        # logic below.
        other.size = 0

        var dest_ptr = self.data.unsafe_offset(len(self))

        for i in range(other_original_size):
            var src_ptr = other.data.unsafe_offset(i)

            # This (TODO: optimistically) moves an element directly from the
            # `other` list into this list using a single `T.__moveinit()__`
            # call, without moving into an intermediate temporary value
            # (avoiding an extra redundant move constructor call).
            dest_ptr.unsafe_write_move_from(src_ptr)

            dest_ptr = dest_ptr.unsafe_offset(1)

        # Update the size now that all new elements have been moved into this
        # list.
        self.size = final_size

    def pop(mut self, i: Int = -1) -> Self.T:
        """Pops a value from the list at the given index.

        Args:
            i: The index of the value to pop.

        Returns:
            The popped value.
        """
        debug_assert(-len(self) <= i < len(self), "pop index out of range")

        var normalized_idx = i
        if i < 0:
            normalized_idx += len(self)

        var ret_val = self.data.unsafe_offset(normalized_idx).unsafe_take_pointee()
        for j in range(normalized_idx + 1, self.size):
            self.data.unsafe_offset(j - 1).unsafe_write_move_from(self.data.unsafe_offset(j))
        self.size -= 1
        if self.size * 4 < self.capacity:
            if self.capacity > 1:
                self._realloc(self.capacity // 2)
        return ret_val^

    def reserve(mut self, new_capacity: Int):
        """Reserves the requested capacity.

        If the current capacity is greater or equal, this is a no-op.
        Otherwise, the storage is reallocated and the date is moved.

        Args:
            new_capacity: The new capacity.
        """
        if self.capacity >= new_capacity:
            return
        self._realloc(new_capacity)

    def resize(mut self, new_size: Int):
        """Resizes the list to the given new size.

        With no new value provided, the new size must be smaller than or equal
        to the current one. Elements at the end are discarded.

        Args:
            new_size: The new size.
        """
        if self.size < new_size:
            abort(
                "You are calling List.resize with a new_size bigger than the"
                " current size. If you want to make the List bigger, provide a"
                " value to fill the new slots with. If not, make sure the new"
                " size is smaller than the current size."
            )
        for i in range(new_size, self.size):
            self.data.unsafe_offset(i).unsafe_deinit_pointee()
        self.size = new_size
        self.reserve(new_size)

    # `index` was removed with the other explicit-self-typed methods
    # above: dead, and invalid on the pinned toolchain once elaborated.

    def clear(mut self):
        """Clears the elements in the list."""
        for i in range(self.size):
            self.data.unsafe_offset(i).unsafe_deinit_pointee()
        self.size = 0

    def steal_data(mut self) -> Pointer[Self.T, MutUntrackedOrigin]:
        """Take ownership of the underlying pointer from the list.

        Returns:
            The underlying data.
        """
        var ptr = self.data
        self.data = Pointer[Self.T, MutUntrackedOrigin](unsafe_from_address=0)
        self.size = 0
        self.capacity = 0
        return ptr

    def __getitem__(ref self, idx: Int) -> ref [self] Self.T:
        """Gets the list element at the given index.

        Args:
            idx: The index of the element.

        Returns:
            A reference to the element at the given index.
        """

        var normalized_idx = idx

        debug_assert(
            -self.size <= normalized_idx < self.size,
            "index: ",
            normalized_idx,
            " is out of bounds for `List` of size: ",
            self.size,
        )
        if normalized_idx < 0:
            normalized_idx += len(self)

        return self.data.unsafe_offset(normalized_idx)[]

    @always_inline
    def unsafe_ptr(self) -> Pointer[Self.T, MutUntrackedOrigin]:
        """Retrieves a pointer to the underlying memory.

        Returns:
            The Pointer to the underlying memory.
        """
        return self.data


def _clip(value: Int, start: Int, end: Int) -> Int:
    return max(start, min(value, end))


def _move_pointee_into_many_elements[
    T: Movable, dest_origin: MutOrigin, src_origin: MutOrigin
](dest: Pointer[T, dest_origin], src: Pointer[T, src_origin], size: Int):
    for i in range(size):
        dest.unsafe_offset(i).unsafe_write_move_from(src.unsafe_offset(i))
        # src.unsafe_offset(i).move_pointee_into(dest + i)
