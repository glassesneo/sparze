const std = @import("std");

/// Determines if a type is Plain Old Data (POD) - can be safely memcpy'd
pub fn isPOD(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum", .void => true,
        .array => |info| isPOD(info.child),
        .@"struct" => |info| {
            // Check all fields are POD
            inline for (info.fields) |field| {
                if (!isPOD(field.type)) return false;
            }
            return true;
        },
        .pointer, .optional, .@"union", .error_union, .error_set => false,
        else => false,
    };
}

/// Trait interface for custom component serialization
/// Components that are not POD must implement this interface via a public Serializer declaration
pub fn ComponentSerializer(comptime T: type) type {
    return struct {
        /// Serialize component to writer
        pub fn serialize(component: T, writer: anytype) !void {
            _ = component;
            _ = writer;
            @compileError("ComponentSerializer.serialize must be implemented for type " ++ @typeName(T));
        }

        /// Deserialize component from reader
        pub fn deserialize(reader: anytype) !T {
            _ = reader;
            @compileError("ComponentSerializer.deserialize must be implemented for type " ++ @typeName(T));
        }
    };
}

/// Check if a type has a custom Serializer
pub fn hasCustomSerializer(comptime T: type) bool {
    return @hasDecl(T, "Serializer");
}

/// Check if a type should be serialized based on optional 'serialized' declaration
/// Types with `serialized: false` will be excluded from serialization
/// Types without the declaration or with `serialized: true` will be included
pub fn shouldSerialize(comptime T: type) bool {
    if (@hasDecl(T, "serialized")) {
        return T.serialized;
    }
    // Default: include in serialization if no declaration present
    return true;
}

/// Get the serializer for a type (custom or default POD)
pub fn getSerializer(comptime T: type) type {
    if (hasCustomSerializer(T)) {
        return T.Serializer;
    } else if (isPOD(T)) {
        return struct {
            pub fn serialize(component: T, writer: anytype) !void {
                const bytes = std.mem.asBytes(&component);
                try writer.writeAll(bytes);
            }

            pub fn deserialize(reader: anytype) !T {
                var component: T = undefined;
                const bytes = std.mem.asBytes(&component);
                // Try new API first, fall back to old API for compatibility
                const ReaderType = if (@typeInfo(@TypeOf(reader)) == .pointer)
                    std.meta.Child(@TypeOf(reader))
                else
                    @TypeOf(reader);

                if (@hasDecl(ReaderType, "readSliceAll")) {
                    try reader.readSliceAll(bytes);
                } else {
                    try reader.readNoEof(bytes);
                }
                return component;
            }
        };
    } else {
        @compileError("Type " ++ @typeName(T) ++ " is not POD and does not have a custom Serializer. " ++
            "Either make it POD or add a public Serializer declaration.");
    }
}

test "isPOD basic types" {
    try std.testing.expect(isPOD(u8));
    try std.testing.expect(isPOD(u16));
    try std.testing.expect(isPOD(u32));
    try std.testing.expect(isPOD(i32));
    try std.testing.expect(isPOD(f32));
    try std.testing.expect(isPOD(f64));
    try std.testing.expect(isPOD(bool));
}

test "isPOD arrays" {
    try std.testing.expect(isPOD([4]u8));
    try std.testing.expect(isPOD([10]f32));
    try std.testing.expect(!isPOD([4]?u8));
}

test "isPOD structs" {
    const Vec2 = struct { x: f32, y: f32 };
    const Vec3 = struct { x: f32, y: f32, z: f32 };
    const Transform = struct { position: Vec3, rotation: f32 };

    try std.testing.expect(isPOD(Vec2));
    try std.testing.expect(isPOD(Vec3));
    try std.testing.expect(isPOD(Transform));
}

test "isPOD non-POD types" {
    const WithPointer = struct { ptr: *u32 };
    const WithSlice = struct { data: []u8 };
    const WithOptional = struct { value: ?u32 };

    try std.testing.expect(!isPOD(WithPointer));
    try std.testing.expect(!isPOD(WithSlice));
    try std.testing.expect(!isPOD(WithOptional));
}

test "hasCustomSerializer" {
    const Simple = struct { x: f32 };
    const WithSerializer = struct {
        x: f32,
        pub const Serializer = struct {
            pub fn serialize(_: @This(), _: anytype) !void {}
            pub fn deserialize(_: anytype) !@This() {
                return .{ .x = 0 };
            }
        };
    };

    try std.testing.expect(!hasCustomSerializer(Simple));
    try std.testing.expect(hasCustomSerializer(WithSerializer));
}

test "shouldSerialize default behavior" {
    const NormalType = struct { x: f32, y: i32 };

    try std.testing.expect(shouldSerialize(NormalType));
}

test "shouldSerialize opt-out behavior" {
    const ExcludedType = struct {
        x: f32,
        pub const serialized = false;
    };

    try std.testing.expect(!shouldSerialize(ExcludedType));
}

test "shouldSerialize with custom serializer" {
    const ExcludedWithSerializer = struct {
        x: f32,
        pub const serialized = false;
        pub const Serializer = struct {
            pub fn serialize(_: @This(), _: anytype) !void {}
            pub fn deserialize(_: anytype) !@This() {
                return .{ .x = 0 };
            }
        };
    };

    try std.testing.expect(!shouldSerialize(ExcludedWithSerializer));
}
