const entity_module = @import("core/entity.zig");
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;
const getIndex = entity_module.getIndex;
const getVersion = entity_module.getVersion;

const sparse_set_module = @import("core/sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;
const AbstractSparseSet = sparse_set_module.AbstractSparseSet;

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
