const std = @import("std");
const StructField = std.builtin.Type.StructField;

const entity_module = @import("../../entity/entity.zig");
const Entity = entity_module.Entity;

pub const FilterType = enum {
    single_query,
    query,
    group,
    single_tag,
    tag_query,
    event_reader,
    event_writer,
};

pub const ModifierType = enum {
    optional,
    exclude,
};

pub fn extractType(comptime T: type) struct { type, ?ModifierType } {
    if (isOptional(T))
        return .{ extractOptional(T), .optional };
    if (@hasDecl(T, "modifier_type"))
        return .{ T.Component, T.modifier_type };
    return .{ T, null };
}

pub fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

pub fn extractOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |Optional| Optional.child,
        else => T,
    };
}

pub fn isFree(comptime T: type) bool {
    return @hasDecl(T, "is_free") and T.is_free;
}

pub fn extractFree(comptime T: type) type {
    if (isFree(T)) return T.Component;
    return T;
}

pub inline fn filterWithModifiers(
    comptime fields: []const StructField,
    entity: Entity,
    self: anytype,
    comptime getStorageFn: anytype,
) bool {
    return inline for (fields) |field| {
        const T, const modifier_type = extractType(field.type);
        if (modifier_type) |modifier| switch (modifier) {
            .optional => continue,
            .exclude => {
                if (getStorageFn(self, T).*.contains(entity))
                    break false;
                continue;
            },
        };
        if (!getStorageFn(self, T).*.contains(entity))
            break false;
    } else true;
}
