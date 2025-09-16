const entity_module = @import("core/entity.zig");
pub const EntityRegistry = entity_module.EntityRegistry;
pub const Entity = entity_module.Entity;
pub const EntityIndex = entity_module.EntityIndex;
pub const max_entities = entity_module.max_entities;
pub const getIndex = entity_module.getIndex;
pub const getVersion = entity_module.getVersion;

const sparse_set_module = @import("core/sparse_set.zig");
pub const SparseSet = sparse_set_module.SparseSet;
pub const AbstractSparseSet = sparse_set_module.AbstractSparseSet;

const system_module = @import("core/system.zig");
pub const SingleQuery = system_module.SingleQuery;
pub const Query = system_module.Query;
pub const Stage = system_module.Stage;

const world_module = @import("core/world.zig");
pub const World = world_module.World;

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
