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
pub const GroupInfo = sparse_set_module.GroupInfo;

const system_module = @import("dynamic/system.zig");
pub const SystemType = system_module.SystemType;
pub const SystemPointerType = system_module.SystemPointerType;
pub const SingleQuery = system_module.SingleQuery;
pub const Group = system_module.Group;
pub const createSystemFunction = system_module.createSystemFunction;

const world_module = @import("dynamic/world.zig");
pub const DynamicWorld = world_module.DynamicWorld;
pub const WorldGroupInfo = world_module.GroupInfo;

const fixed_world_module = @import("fixed/world.zig");
pub const FixedWorld = fixed_world_module.FixedWorld;

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
