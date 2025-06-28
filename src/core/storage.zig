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
    pub fn deinit(self: *SparseSetStorage) void {
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

    pub fn attachComponent(self: *SparseSetStorage, entity: Entity, comptime C: type, component: C) !void {
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

    pub fn hasComponent(self: SparseSetStorage, entity: Entity, comptime C: type) bool {
        const typeName = @typeName(C);
        if (!self.sparseSets.contains(typeName))
            return false;

        if (self.sparseSets.get(typeName)) |sparseSet|
            return sparseSet.contains(entity);
        return false;
    }

    pub fn getComponent(self: SparseSetStorage, entity: Entity, comptime C: type) ?C {
        const typeName = @typeName(C);
        if (self.sparseSets.get(typeName)) |sparseSet|
            return sparseSet.get(entity, C);
        return null;
    }
};

test "SparseSetStorage basic operations" {
    // Define test component types
    const Position = struct {
        x: f32,
        y: f32,
    };

    const Velocity = struct {
        dx: f32,
        dy: f32,
    };

    // Initialize storage
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var storage = SparseSetStorage.init(allocator);
    defer storage.deinit();

    // Create entities
    const entity1 = Entity{ .id = 1 };
    const entity2 = Entity{ .id = 2 };

    // Test empty storage
    try std.testing.expect(!storage.hasComponent(entity1, Position));
    try std.testing.expect(storage.getComponent(entity1, Position) == null);

    // Attach components
    try storage.attachComponent(entity1, Position, .{ .x = 10.0, .y = 20.0 });
    try storage.attachComponent(entity1, Velocity, .{ .dx = 1.0, .dy = 2.0 });
    try storage.attachComponent(entity2, Position, .{ .x = 30.0, .y = 40.0 });

    // Test has component
    try std.testing.expect(storage.hasComponent(entity1, Position));
    try std.testing.expect(storage.hasComponent(entity1, Velocity));
    try std.testing.expect(storage.hasComponent(entity2, Position));
    try std.testing.expect(!storage.hasComponent(entity2, Velocity));

    // Test get component
    if (storage.getComponent(entity1, Position)) |pos| {
        try std.testing.expectEqual(@as(f32, 10.0), pos.x);
        try std.testing.expectEqual(@as(f32, 20.0), pos.y);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    if (storage.getComponent(entity2, Position)) |pos| {
        try std.testing.expectEqual(@as(f32, 30.0), pos.x);
        try std.testing.expectEqual(@as(f32, 40.0), pos.y);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test component absence
    try std.testing.expect(storage.getComponent(entity2, Velocity) == null);
}

test "SparseSetStorage component update" {
    const HealthComponent = struct {
        value: i32,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var storage = SparseSetStorage.init(allocator);
    defer storage.deinit();

    const entity = Entity{ .id = 1 };

    // Attach initial component
    try storage.attachComponent(entity, HealthComponent, .{ .value = 100 });

    // Verify initial value
    if (storage.getComponent(entity, HealthComponent)) |health| {
        try std.testing.expectEqual(@as(i32, 100), health.value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Update component
    try storage.attachComponent(entity, HealthComponent, .{ .value = 75 });

    // Verify updated value
    if (storage.getComponent(entity, HealthComponent)) |health| {
        try std.testing.expectEqual(@as(i32, 75), health.value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }
}

test "SparseSetStorage multiple component types" {
    const Tag = struct {
        name: []const u8,
    };

    const Counter = struct {
        count: usize,
    };

    const Flag = struct {
        active: bool,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var storage = SparseSetStorage.init(allocator);
    defer storage.deinit();

    const entity = Entity{ .id = 42 };

    // Attach different component types
    try storage.attachComponent(entity, Tag, .{ .name = "player" });
    try storage.attachComponent(entity, Counter, .{ .count = 0 });
    try storage.attachComponent(entity, Flag, .{ .active = true });

    // Test that all components exist
    try std.testing.expect(storage.hasComponent(entity, Tag));
    try std.testing.expect(storage.hasComponent(entity, Counter));
    try std.testing.expect(storage.hasComponent(entity, Flag));

    // Test retrieving multiple components
    try std.testing.expectEqualStrings("player", storage.getComponent(entity, Tag).?.name);
    try std.testing.expectEqual(@as(usize, 0), storage.getComponent(entity, Counter).?.count);
    try std.testing.expect(storage.getComponent(entity, Flag).?.active);
}
