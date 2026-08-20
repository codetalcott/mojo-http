comptime ExternalMutPointer = Pointer[_, origin=MutUntrackedOrigin]
comptime ExternalImmutPointer = Pointer[_, origin=ImmUntrackedOrigin]

comptime c_void = NoneType
