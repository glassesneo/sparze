const std = @import("std");
const Entity = @import("entity.zig").Entity;

pub const AbstractSparseSet = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        containsFn: *const fn (*anyopaque, Entity) bool,
        removeFn: *const fn (*anyopaque, Entity) anyerror!void,
        iteratorFn: *const fn (*anyopaque, *anyopaque) void,
        deinitFn: *const fn (*anyopaque) void,
    };

    pub fn insert(self: *const AbstractSparseSet, entity: Entity, component: *anyopaque) !void {
        return self.vtable.insertFn(self.instance, entity, component);
    }

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime T: type) ?T {
        if (self.vtable.getFn(self.instance, entity)) |component| {
            const typedPtr = castTo(T, component);
            return typedPtr.*;
        }
        return null;
    }

    pub fn contains(self: *const AbstractSparseSet, entity: Entity) bool {
        return self.vtable.containsFn(self.instance, entity);
    }

    pub fn remove(self: *const AbstractSparseSet, entity: Entity) !void {
        return try self.vtable.removeFn(self.instance, entity);
    }

    pub fn iterator(self: *const AbstractSparseSet, comptime T: type, iter: *SparseSetIterator(T)) void {
        self.vtable.iteratorFn(self.instance, iter);
    }

    pub fn deinit(self: *const AbstractSparseSet) void {
        return self.vtable.deinitFn(self.instance);
    }

    fn castTo(comptime T: type, ptr: *anyopaque) *T {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn init(comptime T: type, instance: *T) AbstractSparseSet {
        const vtable = comptime VTable{
            .insertFn = struct {
                fn insert(ptr: *anyopaque, entity: Entity, component_ptr: *anyopaque) !void {
                    const self = castTo(T, ptr);
                    const component = castTo(T.Component, component_ptr);
                    return self.insert(entity, component.*);
                }
            }.insert,
            .getFn = struct {
                fn get(ptr: *anyopaque, entity: Entity) ?*anyopaque {
                    const self = castTo(T, ptr);
                    if (self.index_table.get(entity.id)) |index| {
                        return @ptrCast(&self.components.items[index]);
                    }
                    return null;
                }
            }.get,
            .containsFn = struct {
                fn contains(ptr: *anyopaque, entity: Entity) bool {
                    const self = castTo(T, ptr);
                    return self.contains(entity);
                }
            }.contains,
            .removeFn = struct {
                fn remove(ptr: *anyopaque, entity: Entity) !void {
                    const self = castTo(T, ptr);
                    try self.remove(entity);
                }
            }.remove,
            .iteratorFn = struct {
                fn iterator(ptr: *anyopaque, iter: *anyopaque) void {
                    const self = castTo(T, ptr);
                    const iter_ptr = castTo(SparseSetIterator(T.Component), iter);
                    iter_ptr.* = SparseSetIterator(T.Component).init(self);
                }
            }.iterator,
            .deinitFn = struct {
                fn deinit(ptr: *anyopaque) void {
                    const self = castTo(T, ptr);
                    return self.deinit();
                }
            }.deinit,
        };
        return .{
            .vtable = &vtable,
            .instance = instance,
        };
    }
};

pub fn SparseSet(comptime C: type) type {
    return struct {
        components: std.ArrayList(C),
        index_table: std.AutoHashMap(Entity.EntityId, u32),
        free_indexes: std.ArrayList(u32),
        const Self = @This();
        pub const Component = C;

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .components = .init(allocator),
                .index_table = .init(allocator),
                .free_indexes = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.components.deinit();
            self.index_table.deinit();
        }

        fn contains(self: Self, entity: Entity) bool {
            return self.index_table.contains(entity.id);
        }

        fn insert(self: *Self, entity: Entity, component: C) !void {
            if (self.index_table.get(entity.id)) |index| {
                self.components.items[index] = component;
                return;
            }

            if (self.free_indexes.pop()) |index| {
                try self.index_table.put(entity.id, index);
                self.components.items[index] = component;
                return;
            }

            const index = self.index_table.count();
            try self.index_table.put(entity.id, index);
            try self.components.append(component);
        }

        fn remove(self: *Self, entity: Entity) !void {
            if (self.index_table.get(entity.id)) |index| {
                try self.free_indexes.append(index);
                _ = self.index_table.remove(entity.id);
            }
        }

        pub fn abstract(self: *Self) AbstractSparseSet {
            return AbstractSparseSet.init(Self, self);
        }
    };
}

fn SparseSetIterator(comptime C: type) type {
    return struct {
        const Self = @This();
        sparse_set: *const SparseSet(C),
        iter: std.AutoHashMap(Entity.EntityId, u32).Iterator,
        pub fn init(sparse_set: *const SparseSet(C)) Self {
            return Self{
                .sparse_set = sparse_set,
                .iter = sparse_set.index_table.iterator(),
            };
        }

        pub fn next(self: *Self) ?struct { id: Entity.EntityId, component: *const C } {
            if (self.iter.next()) |entry| {
                return .{
                    .id = entry.key_ptr.*,
                    .component = &self.sparse_set.components.items[entry.value_ptr.*],
                };
            }
            return null;
        }
        pub fn mutableNext(self: *Self) ?struct { id: Entity.EntityId, component: *C } {
            if (self.iter.next()) |entry| {
                return .{
                    .id = entry.key_ptr.*,
                    .component = &self.sparse_set.components.items[entry.value_ptr.*],
                };
            }
            return null;
        }
        pub fn reset(self: *Self) void {
            self.iter = self.sparse_set.index_table.iterator();
        }
    };
}

test "SparseSet basic operations" {
    const TestComponent = struct {
        value: i32,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sparseSet = SparseSet(TestComponent).init(allocator);
    defer sparseSet.deinit();

    const e1 = Entity.init(1, 0);
    const e2 = Entity.init(2, 0);
    const e3 = Entity.init(5, 0);

    // Test initial state
    try std.testing.expect(!sparseSet.contains(e1));

    // Test insert
    try sparseSet.insert(e1, .{ .value = 10 });
    try sparseSet.insert(e2, .{ .value = 20 });
    try std.testing.expect(sparseSet.contains(e1));
    try std.testing.expect(sparseSet.contains(e2));
    try std.testing.expect(!sparseSet.contains(e3));

    // Test component retrieval through indexTable
    if (sparseSet.index_table.get(e1.id)) |index| {
        try std.testing.expectEqual(@as(i32, 10), sparseSet.components.items[index].value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test updating existing component
    try sparseSet.insert(e1, .{ .value = 15 });
    if (sparseSet.index_table.get(e1.id)) |index| {
        try std.testing.expectEqual(@as(i32, 15), sparseSet.components.items[index].value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test removal
    try sparseSet.remove(e1);
    try std.testing.expect(!sparseSet.contains(e1));
    try std.testing.expect(sparseSet.contains(e2));

    // Test removing non-existent entity (should not crash)
    try sparseSet.remove(e3);
}

test "AbstractSparseSet interface" {
    const TestComponent = struct {
        value: i32,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sparseSet = SparseSet(TestComponent).init(allocator);
    var abstract = sparseSet.abstract();
    defer abstract.deinit();

    const e1 = Entity.init(1, 0);
    const e2 = Entity.init(2, 0);

    // Test contains through abstract interface
    try std.testing.expect(!abstract.contains(e1));

    // Test insert through abstract interface
    var comp1 = TestComponent{ .value = 42 };
    try abstract.insert(e1, &comp1);
    try std.testing.expect(abstract.contains(e1));

    // Test get through abstract interface
    if (abstract.get(e1, TestComponent)) |component| {
        try std.testing.expectEqual(@as(i32, 42), component.value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test non-existent component get
    try std.testing.expect(abstract.get(e2, TestComponent) == null);

    // Test remove through abstract interface
    try abstract.remove(e1);
    try std.testing.expect(!abstract.contains(e1));
}

test "SparseSet edge cases" {
    const TestComponent = struct {
        value: i32,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var set = SparseSet(TestComponent).init(arena.allocator());
    defer set.deinit();

    const e1 = Entity.init(1, 0);
    const e2 = Entity.init(2, 0);

    // Remove non-existent entity (no crash)
    try set.remove(e1);

    // Insert, remove, reuse index
    try set.insert(e1, .{ .value = 10 });
    try set.remove(e1);
    try set.insert(e2, .{ .value = 20 });
    try std.testing.expect(set.contains(e2));
    try std.testing.expect(!set.contains(e1));

    // Remove again, freeIndex should have one entry
    try set.remove(e2);
    try std.testing.expect(set.free_indexes.items.len == 1);
}

test "SparseSetIterator yields correct entities and components" {
    const TestComponent = struct { value: i32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var set = SparseSet(TestComponent).init(arena.allocator());
    defer set.deinit();
    const e1 = Entity.init(1, 0);
    const e2 = Entity.init(2, 0);
    try set.insert(e1, .{ .value = 10 });
    try set.insert(e2, .{ .value = 20 });

    var abstract = set.abstract();
    var iter: SparseSetIterator(TestComponent) = undefined;
    abstract.iterator(TestComponent, &iter);
    var found = [_]bool{ false, false };
    while (iter.next()) |entry| {
        if (entry.id == e1.id) {
            try std.testing.expectEqual(@as(i32, 10), entry.component.value);
            found[0] = true;
        } else if (entry.id == e2.id) {
            try std.testing.expectEqual(@as(i32, 20), entry.component.value);
            found[1] = true;
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(found[0] and found[1]);
}
