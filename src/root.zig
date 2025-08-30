const entity_module = @import("core/entity.zig");
pub const EntityRegistry = entity_module.EntityRegistry;
pub const Entity = entity_module.Entity;
pub const getIndex = entity_module.getIndex;
pub const getVersion = entity_module.getVersion;

const sparse_set_module = @import("core/sparse_set.zig");
pub const SparseSet = sparse_set_module.SparseSet;
pub const AbstractSparseSet = sparse_set_module.AbstractSparseSet;

const world_module = @import("core/world.zig");
pub const World = world_module.World;

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
