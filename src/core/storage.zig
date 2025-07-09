const std = @import("std");

const Entity = @import("entity.zig").Entity;

const sparse_set_module = @import("sparse_set.zig");
const SparseSet = sparse_set_module.SparseSet;
const AbstractSparseSet = sparse_set_module.AbstractSparseSet;

const resource_module = @import("resource.zig");
const Resource = resource_module.Resource;
const AbstractResource = resource_module.AbstractResource;

pub const SparseSetStorage = struct {
    sparse_sets: std.AutoHashMap(TypeId, AbstractSparseSet),
    component_storage: std.AutoHashMap(TypeId, StorageInfo),
    allocator: std.mem.Allocator,

    const StorageInfo = struct {
        ptr: *anyopaque,
        destroyFn: *const fn (*anyopaque, std.mem.Allocator) void,
    };
    const Self = SparseSetStorage;

    const TypeId = u64;
    fn typeId(comptime T: type) TypeId {
        return comptime std.hash_map.hashString(@typeName(T));
    }

    pub fn destroyTypedStorage(comptime T: type) *const fn (*anyopaque, std.mem.Allocator) void {
        return struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const typed_ptr = @as(*T, @ptrCast(@alignCast(ptr)));
                allocator.destroy(typed_ptr);
            }
        }.destroy;
    }

    pub fn init(allocator: std.mem.Allocator) SparseSetStorage {
        return SparseSetStorage{
            .sparse_sets = .init(allocator),
            .component_storage = .init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        var iter = self.component_storage.iterator();
        while (iter.next()) |entry| {
            const type_id = entry.key_ptr.*;
            const storage_info = entry.value_ptr.*;

            if (self.sparse_sets.get(type_id)) |sparse_set| {
                sparse_set.deinit();

                storage_info.destroyFn(storage_info.ptr, self.allocator);
            }
        }

        self.sparse_sets.deinit();
        self.component_storage.deinit();
    }

    pub fn attachComponent(self: *Self, entity: Entity, comptime C: type, component: C) !void {
        const type_id = comptime typeId(C);
        if (!self.sparse_sets.contains(type_id)) {
            var sparse_set = try self.allocator.create(SparseSet(C));
            sparse_set.* = SparseSet(C).init(self.allocator);

            const storageInfo = StorageInfo{
                .ptr = @ptrCast(sparse_set),
                .destroyFn = destroyTypedStorage(SparseSet(C)),
            };
            try self.component_storage.put(type_id, storageInfo);

            const abstract_sparse_set = sparse_set.abstract();
            try self.sparse_sets.put(type_id, abstract_sparse_set);
        }

        var component_copy = component;
        try self.sparse_sets.get(type_id).?.insert(entity, &component_copy);
    }

    pub fn hasComponent(self: Self, entity: Entity, comptime C: type) bool {
        const type_id = comptime typeId(C);
        if (self.sparse_sets.get(type_id)) |sparse_set|
            return sparse_set.contains(entity);
        return false;
    }

    pub fn getComponent(self: Self, entity: Entity, comptime C: type) ?C {
        const type_id = comptime typeId(C);
        if (self.sparse_sets.get(type_id)) |sparse_set|
            return sparse_set.get(entity, C);
        return null;
    }

    pub fn getComponentPtr(self: *Self, entity: Entity, comptime C: type) ?*C {
        const type_id = comptime typeId(C);
        if (self.sparse_sets.getPtr(type_id)) |sparse_set|
            return sparse_set.getPtr(entity, C);
        return null;
    }

    pub fn removeComponent(self: *Self, entity: Entity, comptime C: type) !void {
        const type_id = comptime typeId(C);
        if (self.sparse_sets.get(type_id)) |sparse_set| {
            try sparse_set.remove(entity);
        }
    }

    pub fn removeAllComponents(self: *Self, entity: Entity) !void {
        var iter = self.sparse_sets.iterator();
        while (iter.next()) |entry| {
            const sparse_set = entry.value_ptr.*;
            try sparse_set.remove(entity);
        }
    }
};

test "SparseSetStorage component operations" {
    // Setup test environment
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var storage = SparseSetStorage.init(arena.allocator());
    defer storage.deinit();

    const e1 = Entity.init(1, 0);
    const e2 = Entity.init(2, 0);

    // Test component types
    const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    const Health = struct {
        value: i32 = 100,
    };

    // Test initial state
    try std.testing.expect(!storage.hasComponent(e1, Position));
    try std.testing.expect(!storage.hasComponent(e1, Health));
    try std.testing.expect(storage.getComponent(e1, Position) == null);

    // Test attaching components
    try storage.attachComponent(e1, Position, .{ .x = 10, .y = 20 });
    try storage.attachComponent(e1, Health, .{ .value = 50 });
    try storage.attachComponent(e2, Position, .{ .x = 30, .y = 40 });

    // Test has component
    try std.testing.expect(storage.hasComponent(e1, Position));
    try std.testing.expect(storage.hasComponent(e1, Health));
    try std.testing.expect(storage.hasComponent(e2, Position));
    try std.testing.expect(!storage.hasComponent(e2, Health));

    // Test get component
    if (storage.getComponent(e1, Position)) |pos| {
        try std.testing.expectEqual(@as(f32, 10), pos.x);
        try std.testing.expectEqual(@as(f32, 20), pos.y);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    if (storage.getComponent(e1, Health)) |health| {
        try std.testing.expectEqual(@as(i32, 50), health.value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test updating component
    try storage.attachComponent(e1, Health, .{ .value = 75 });
    if (storage.getComponent(e1, Health)) |health| {
        try std.testing.expectEqual(@as(i32, 75), health.value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test getComponentPtr for mutable access
    if (storage.getComponentPtr(e1, Position)) |pos_ptr| {
        try std.testing.expectEqual(@as(f32, 10), pos_ptr.x);
        try std.testing.expectEqual(@as(f32, 20), pos_ptr.y);

        // Test in-place modification through pointer
        pos_ptr.x = 100;
        pos_ptr.y = 200;

        // Verify the modification persisted
        if (storage.getComponent(e1, Position)) |modified_pos| {
            try std.testing.expectEqual(@as(f32, 100), modified_pos.x);
            try std.testing.expectEqual(@as(f32, 200), modified_pos.y);
        } else {
            try std.testing.expect(false); // Should not reach here
        }
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test getComponentPtr for non-existent component
    try std.testing.expect(storage.getComponentPtr(e2, Health) == null);

    // Test remove single component
    try storage.removeComponent(e1, Health);
    try std.testing.expect(!storage.hasComponent(e1, Health));
    try std.testing.expect(storage.hasComponent(e1, Position)); // Position should remain

    // Test remove all components
    try storage.removeAllComponents(e1);
    try std.testing.expect(!storage.hasComponent(e1, Position));
    try std.testing.expect(!storage.hasComponent(e1, Health));

    // e2 should be unaffected
    try std.testing.expect(storage.hasComponent(e2, Position));
}

test "SparseSetStorage edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var storage = SparseSetStorage.init(arena.allocator());
    defer storage.deinit();

    const e1 = Entity.init(1, 0);
    const nonExistentEntity = Entity.init(999, 0);

    const TestComponent = struct {
        value: i32 = 0,
    };

    // Removing component from entity that doesn't have it (shouldn't crash)
    try storage.removeComponent(e1, TestComponent);

    // Removing all components from entity without components (shouldn't crash)
    try storage.removeAllComponents(nonExistentEntity);

    // Attaching then retrieving component
    try storage.attachComponent(e1, TestComponent, .{ .value = 42 });
    try std.testing.expect(storage.hasComponent(e1, TestComponent));

    // Get non-existent component
    try std.testing.expect(storage.getComponent(nonExistentEntity, TestComponent) == null);
}

pub const ResourceStorage = struct {
    resources: std.AutoHashMap(TypeId, AbstractResource),
    value_storage: std.AutoHashMap(TypeId, StorageInfo),
    allocator: std.mem.Allocator,

    const StorageInfo = struct {
        ptr: *anyopaque,
        destroyFn: *const fn (*anyopaque, std.mem.Allocator) void,
    };
    const Self = ResourceStorage;

    const TypeId = u64;
    fn typeId(comptime T: type) TypeId {
        return comptime std.hash_map.hashString(@typeName(T));
    }

    pub fn destroyTypedStorage(comptime T: type) *const fn (*anyopaque, std.mem.Allocator) void {
        return struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const typed_ptr = @as(*T, @ptrCast(@alignCast(ptr)));
                allocator.destroy(typed_ptr);
            }
        }.destroy;
    }

    pub fn init(allocator: std.mem.Allocator) ResourceStorage {
        return ResourceStorage{
            .resources = .init(allocator),
            .value_storage = .init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        var iter = self.value_storage.iterator();
        while (iter.next()) |entry| {
            const type_id = entry.key_ptr.*;
            const storage_info = entry.value_ptr.*;

            if (self.resources.get(type_id)) |resource| {
                resource.deinit();

                storage_info.destroyFn(storage_info.ptr, self.allocator);
            }
        }

        self.resources.deinit();
        self.value_storage.deinit();
    }

    pub fn put(self: *Self, comptime T: type, value: T) !void {
        const type_id = comptime typeId(T);
        var resource = try self.allocator.create(Resource(T));
        resource.* = try Resource(T).init(self.allocator);
        resource.*.value = value;

        const storageInfo = StorageInfo{
            .ptr = @ptrCast(resource),
            .destroyFn = destroyTypedStorage(Resource(T)),
        };
        try self.value_storage.put(type_id, storageInfo);

        const abstract_resource = try resource.abstract();
        try self.resources.put(type_id, abstract_resource);
    }

    pub fn get(self: Self, comptime T: type) ?T {
        const type_id = comptime typeId(T);
        return if (self.resources.get(type_id)) |resource|
            resource.get(T)
        else
            null;
    }

    pub fn getPtr(self: *Self, comptime T: type) ?*T {
        const type_id = comptime typeId(T);
        return if (self.resources.getPtr(type_id)) |resource|
            resource.getPtr(T)
        else
            null;
    }
};

test "ResourceStorage put/get/update" {
    const expect = std.testing.expect;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var storage = ResourceStorage.init(arena.allocator());
    defer storage.deinit();

    const Config = struct {
        value: i32,
        pub fn deinit(_: *@This()) void {}
    };

    // Put a resource and get it
    try storage.put(Config, Config{ .value = 123 });
    if (storage.get(Config)) |got| {
        try expect(got.value == 123);
    } else {
        try expect(false);
    }

    // Update the resource
    try storage.put(Config, Config{ .value = 456 });
    if (storage.get(Config)) |got| {
        try expect(got.value == 456);
    } else {
        try expect(false);
    }

    // Test getPtr for mutable access
    if (storage.getPtr(Config)) |config_ptr| {
        try expect(config_ptr.value == 456);

        // Test in-place modification through pointer
        config_ptr.value = 789;

        // Verify the modification persisted
        if (storage.get(Config)) |modified_config| {
            try expect(modified_config.value == 789);
        } else {
            try expect(false);
        }
    } else {
        try expect(false);
    }

    // Non-existent resource returns null
    const Dummy = struct { x: u8 };
    try expect(storage.get(Dummy) == null);
    try expect(storage.getPtr(Dummy) == null);
}
