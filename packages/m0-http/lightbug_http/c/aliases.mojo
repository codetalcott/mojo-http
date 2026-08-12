comptime ExternalMutUnsafePointer = Pointer[_, origin=MutUntrackedOrigin]
comptime ExternalImmutUnsafePointer = Pointer[_, origin=ImmutExternalOrigin]

comptime c_void = NoneType
