const entity_module = @import("entity/entity.zig");
pub const EntityRegistry = entity_module.EntityRegistry;
pub const Entity = entity_module.Entity;
pub const EntityIndex = entity_module.EntityIndex;
pub const max_entities = entity_module.max_entities;
pub const getIndex = entity_module.getIndex;
pub const getVersion = entity_module.getVersion;

const sparse_set_module = @import("storage/sparse_set.zig");
pub const SparseSet = sparse_set_module.SparseSet;
pub const GroupInfo = sparse_set_module.GroupInfo;

const world_module = @import("world.zig");
pub const World = world_module.World;

const filter_module = @import("query/filter.zig");
pub const FilterType = filter_module.FilterType;
pub const SingleQuery = filter_module.SingleQuery;
pub const Query = filter_module.Query;
pub const Group = filter_module.Group;
pub const SingleTag = filter_module.SingleTag;
pub const TagQuery = filter_module.TagQuery;
pub const Exclude = filter_module.Exclude;
pub const Free = filter_module.Free;
pub const Resource = filter_module.Resource;
pub const ResourceMut = filter_module.ResourceMut;
pub const EventReader = filter_module.EventReader;
pub const EventWriter = filter_module.EventWriter;

const system_module = @import("system/system.zig");
pub const Commands = system_module.Commands;
pub const CommandBuffer = system_module.CommandBuffer;
pub const createSystemFunction = system_module.createSystemFunction;

const event_storage_module = @import("storage/event_storage.zig");
pub const EventStorage = event_storage_module.EventStorage;

// Serialization module
pub const serialization = struct {
    pub const traits = @import("serialization/traits.zig");
    pub const format = @import("serialization/format.zig");
    pub const world = @import("serialization/world.zig");

    // Re-export common serialization functions
    pub const isPOD = traits.isPOD;
    pub const hasCustomSerializer = traits.hasCustomSerializer;
    pub const getSerializer = traits.getSerializer;
    pub const ComponentSerializer = traits.ComponentSerializer;
    pub const shouldSerialize = traits.shouldSerialize;
};

test {
    _ = @import("storage/tag_storage_test.zig");
    _ = @import("query/filter_test.zig");
    _ = @import("system/system_test.zig");
    std.testing.refAllDecls(@This());
}

const std = @import("std");
