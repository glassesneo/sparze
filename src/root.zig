const entity_module = @import("core/entity.zig");
pub const EntityRegistry = entity_module.EntityRegistry;
pub const Entity = entity_module.Entity;
pub const EntityIndex = entity_module.EntityIndex;
pub const max_entities = entity_module.max_entities;
pub const getIndex = entity_module.getIndex;
pub const getVersion = entity_module.getVersion;

const sparse_set_module = @import("core/sparse_set.zig");
pub const SparseSet = sparse_set_module.SparseSet;
pub const GroupInfo = sparse_set_module.GroupInfo;

const world_module = @import("world.zig");
pub const World = world_module.World;

const filter_module = @import("filter.zig");
pub const FilterType = filter_module.FilterType;
pub const SingleQuery = filter_module.SingleQuery;
pub const Query = filter_module.Query;
pub const Group = filter_module.Group;
pub const SingleTag = filter_module.SingleTag;
pub const TagQuery = filter_module.TagQuery;
pub const Exclude = filter_module.Exclude;
pub const Resource = filter_module.Resource;

const system_module = @import("system.zig");
pub const Commands = system_module.Commands;
pub const CommandBuffer = system_module.CommandBuffer;
pub const createSystemFunction = system_module.createSystemFunction;

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
