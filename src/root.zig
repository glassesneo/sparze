const entity_module = @import("entity/entity.zig");
pub const Entity = entity_module.Entity;

const world_module = @import("world.zig");
pub const World = world_module.World;

const filter_module = @import("query/filter.zig");
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

// Serialization module
pub const serialization = struct {
    pub const compat = @import("serialization/compat.zig");
};

test {
    _ = @import("storage/storage_test.zig");
    _ = @import("query/query_test.zig");
    _ = @import("system/system_test.zig");
    _ = @import("world_test.zig");
    _ = @import("serialization/serialization_test.zig");
    std.testing.refAllDecls(@This());
}

const std = @import("std");
