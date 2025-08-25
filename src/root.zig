const entity_module = @import("core/entity.zig");
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;
const getIndex = entity_module.getIndex;
const getVersion = entity_module.getVersion;

comptime {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
