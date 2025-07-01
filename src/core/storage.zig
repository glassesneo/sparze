const std = @import("std");

const Entity = @import("entity.zig").Entity;

const sparse_set = @import("sparse_set.zig");
const SparseSet = sparse_set.SparseSet;
const AbstractSparseSet = sparse_set.AbstractSparseSet;

pub const SparseSetStorage = struct {
    sparseSets: std.StringHashMap(AbstractSparseSet),
    componentStorage: std.StringHashMap(StorageInfo),
    allocator: std.mem.Allocator,

    const StorageInfo = struct {
        ptr: *anyopaque,
        destroyFn: *const fn (*anyopaque, std.mem.Allocator) void,
    };
    const Self = SparseSetStorage;

    pub fn destroyTypedStorage(comptime T: type) *const fn (*anyopaque, std.mem.Allocator) void {
        return struct {
            fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const typedPtr = @as(*T, @ptrCast(@alignCast(ptr)));
                allocator.destroy(typedPtr);
            }
        }.destroy;
    }

    pub fn init(allocator: std.mem.Allocator) SparseSetStorage {
        return SparseSetStorage{
            .sparseSets = .init(allocator),
            .componentStorage = .init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        var iter = self.componentStorage.iterator();
        while (iter.next()) |entry| {
            const typeName = entry.key_ptr.*;
            const storageInfo = entry.value_ptr.*;

            if (self.sparseSets.get(typeName)) |sparseSet| {
                sparseSet.deinit();

                storageInfo.destroyFn(storageInfo.ptr, self.allocator);
            }
        }

        self.sparseSets.deinit();
        self.componentStorage.deinit();
    }

    pub fn attachComponent(self: *Self, entity: Entity, comptime C: type, component: C) !void {
        const typeName = @typeName(C);
        if (!self.sparseSets.contains(typeName)) {
            var sparseSet = try self.allocator.create(SparseSet(C));
            sparseSet.* = SparseSet(C).init(self.allocator);

            const storageInfo = StorageInfo{
                .ptr = @ptrCast(sparseSet),
                .destroyFn = destroyTypedStorage(SparseSet(C)),
            };
            try self.componentStorage.put(typeName, storageInfo);

            const abstractSparseSet = sparseSet.abstract();
            try self.sparseSets.put(typeName, abstractSparseSet);
        }

        var componentCopy = component;
        try self.sparseSets.get(typeName).?.insert(entity, &componentCopy);
    }

    pub fn hasComponent(self: Self, entity: Entity, comptime C: type) bool {
        const typeName = @typeName(C);
        if (!self.sparseSets.contains(typeName))
            return false;

        if (self.sparseSets.get(typeName)) |sparseSet|
            return sparseSet.contains(entity);
        return false;
    }

    pub fn getComponent(self: Self, entity: Entity, comptime C: type) ?C {
        const typeName = @typeName(C);
        if (self.sparseSets.get(typeName)) |sparseSet|
            return sparseSet.get(entity, C);
        return null;
    }

    pub fn removeComponent(self: *Self, entity: Entity, comptime C: type) !void {
        const typeName = @typeName(C);
        if (self.sparseSets.get(typeName)) |sparseSet| {
            try sparseSet.remove(entity);
        }
    }

    pub fn removeAllComponents(self: *Self, entity: Entity) !void {
        var iter = self.sparseSets.iterator();
        while (iter.next()) |entry| {
            const sparseSet = entry.value_ptr.*;
            try sparseSet.remove(entity);
        }
    }
};

test "SparseSetStorage component operations" {
    // Setup test environment
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var storage = SparseSetStorage.init(arena.allocator());
    defer storage.deinit();

    const e1 = Entity{ .id = 1 };
    const e2 = Entity{ .id = 2 };

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

    const e1 = Entity{ .id = 1 };
    const nonExistentEntity = Entity{ .id = 999 };

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
