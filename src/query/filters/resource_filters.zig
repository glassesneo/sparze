/// Resource filters provide compile-time type-safe access to global singleton resources.
/// Resources are injected into system functions as pointer types, allowing direct field access.
///
/// Usage:
/// ```zig
/// fn mySystem(delta: sparze.Resource(DeltaTime), score: sparze.ResourceMut(Score)) !void {
///     const dt = delta.dt;      // Direct field access (no .value needed)
///     score.points += 100;      // Mutable access
/// }
/// ```
/// Read-only resource access. Returns `*const T` directly.
/// Zig allows field access through pointers, so `delta.dt` works without dereferencing.
pub fn Resource(comptime T: type) type {
    return *const T;
}

/// Mutable resource access. Returns `*T` directly.
/// Use this when you need to modify the resource value.
pub fn ResourceMut(comptime T: type) type {
    return *T;
}
