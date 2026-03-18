comptime ExternalMutUnsafePointer = UnsafePointer[_, origin=MutExternalOrigin]
comptime ExternalImmutUnsafePointer = UnsafePointer[_, origin=ImmutExternalOrigin]

comptime c_void = NoneType
