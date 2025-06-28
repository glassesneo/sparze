const std = @import("std");
const Entity = @import("entity.zig").Entity;

pub const AbstractSparseSet = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        containsFn: *const fn (*anyopaque, Entity) bool,
        removeFn: *const fn (*anyopaque, Entity) void,
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

    pub fn remove(self: *const AbstractSparseSet, entity: Entity) void {
        return self.vtable.removeFn(self.instance, entity);
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
                fn insert(ptr: *anyopaque, entity: Entity, cPtr: *anyopaque) !void {
                    const self = castTo(T, ptr);
                    const component = castTo(T.Component, cPtr);
                    return self.insert(entity, component.*);
                }
            }.insert,
            .getFn = struct {
                fn get(ptr: *anyopaque, entity: Entity) ?*anyopaque {
                    const self = castTo(T, ptr);
                    if (self.indexTable.get(entity.id)) |index| {
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
                fn remove(ptr: *anyopaque, entity: Entity) void {
                    const self = castTo(T, ptr);
                    self.remove(entity);
                }
            }.remove,
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
        indexTable: std.AutoHashMap(usize, u32),
        const Self = @This();
        pub const Component = C;

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .components = .init(allocator),
                .indexTable = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.components.deinit();
            self.indexTable.deinit();
        }

        fn contains(self: Self, entity: Entity) bool {
            return self.indexTable.contains(entity.id);
        }

        fn insert(self: *Self, entity: Entity, component: C) !void {
            if (self.indexTable.get(entity.id)) |index| {
                self.components.items[index] = component;
            } else {
                try self.components.append(component);

                const newIndex: u32 = self.indexTable.count();
                try self.indexTable.put(entity.id, newIndex);
            }
        }

        fn remove(self: *Self, entity: Entity) void {
            if (self.indexTable.get(entity.id)) |index| {
                _ = self.indexTable.remove(entity.id);
                _ = self.components.orderedRemove(index);
            }
        }

        pub fn abstract(self: *Self) AbstractSparseSet {
            return AbstractSparseSet.init(Self, self);
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

    const e1 = Entity{ .id = 0 };
    const e2 = Entity{ .id = 1 };
    const e3 = Entity{ .id = 5 }; // Testing with non-sequential ID

    // Test initial state
    try std.testing.expect(!sparseSet.contains(e1));

    // Test insert
    try sparseSet.insert(e1, .{ .value = 10 });
    try sparseSet.insert(e2, .{ .value = 20 });
    try std.testing.expect(sparseSet.contains(e1));
    try std.testing.expect(sparseSet.contains(e2));
    try std.testing.expect(!sparseSet.contains(e3));

    // Test component retrieval through indexTable
    if (sparseSet.indexTable.get(e1.id)) |index| {
        try std.testing.expectEqual(@as(i32, 10), sparseSet.components.items[index].value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test updating existing component
    try sparseSet.insert(e1, .{ .value = 15 });
    if (sparseSet.indexTable.get(e1.id)) |index| {
        try std.testing.expectEqual(@as(i32, 15), sparseSet.components.items[index].value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test removal
    sparseSet.remove(e1);
    try std.testing.expect(!sparseSet.contains(e1));
    try std.testing.expect(sparseSet.contains(e2));

    // Test removing non-existent entity (should not crash)
    sparseSet.remove(e3);
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

    const e1 = Entity{ .id = 0 };
    const e2 = Entity{ .id = 1 };

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
    abstract.remove(e1);
    try std.testing.expect(!abstract.contains(e1));
}
