const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const entity_module = @import("entity.zig");
pub const entity_id_limit = entity_module.entity_id_limit;
const Entity = struct {
    id: u16,

    pub fn init(id: u16) Entity {
        return .{ .id = id };
    }
};

pub const AbstractSparseSet = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) void,
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        containsFn: *const fn (*anyopaque, Entity) bool,
        removeFn: *const fn (*anyopaque, Entity) void,
    };

    pub fn insert(self: *const AbstractSparseSet, entity: Entity, component: *anyopaque) void {
        return self.vtable.insertFn(self.instance, entity, component);
    }

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime T: type) ?T {
        if (self.vtable.getFn(self.instance, entity)) |component| {
            const typed_ptr = castTo(T, component);
            return typed_ptr.*;
        }
        return null;
    }

    pub fn getPtr(self: *AbstractSparseSet, entity: Entity, comptime T: type) ?*T {
        return if (self.vtable.getFn(self.instance, entity)) |component|
            castTo(T, component)
        else
            null;
    }

    pub fn contains(self: *const AbstractSparseSet, entity: Entity) bool {
        return self.vtable.containsFn(self.instance, entity);
    }

    pub fn remove(self: *const AbstractSparseSet, entity: Entity) void {
        return self.vtable.removeFn(self.instance, entity);
    }

    fn castTo(comptime T: type, ptr: *anyopaque) *T {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn init(comptime T: type, instance: *T) AbstractSparseSet {
        const vtable = comptime VTable{
            .insertFn = struct {
                fn insert(ptr: *anyopaque, entity: Entity, component_ptr: *anyopaque) void {
                    const self = castTo(T, ptr);
                    const component = castTo(T.Component, component_ptr);
                    return self.insert(entity, component.*);
                }
            }.insert,
            .getFn = struct {
                fn get(ptr: *anyopaque, entity: Entity) ?*anyopaque {
                    const self = castTo(T, ptr);
                    const dense_index = self.sparse[entity.id] orelse return null;
                    return @ptrCast(&self.components[dense_index]);
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
        };
        return .{
            .vtable = &vtable,
            .instance = instance,
        };
    }
};

pub fn SparseSet(comptime Component: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        sparse_array: [entity_id_limit]?u16, // index: entity id, element: index of components
        packed_array: ArrayList(u16), // element: entity id
        components: ArrayList(Component),

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .sparse_array = [_]?u16{null} ** entity_id_limit,
                .packed_array = .init(allocator),
                .components = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.packed_array.deinit();
            self.components.deinit();
        }

        fn contains(self: Self, entity: Entity) bool {
            if (entity.id >= entity_id_limit) return false;
            const dense_index = self.sparse_array[entity.id] orelse return false;
            if (dense_index >= self.packed_array.items.len) return false;
            return entity.id == self.packed_array.items[dense_index];
        }

        fn get(self: Self, entity: Entity) ?Component {
            if (!self.contains(entity)) return null;
            const dense_index = self.sparse_array[entity.id].?;
            return self.components.items[dense_index];
        }

        fn insert(self: *Self, entity: Entity, component: Component) !void {
            if (self.contains(entity)) {
                const dense_index = self.sparse_array[entity.id].?;
                self.components.items[dense_index] = component;
                self.packed_array.items[dense_index] = entity.id;
                return;
            }

            const dense_index: u16 = @intCast(self.components.items.len);
            try self.components.append(component);
            try self.packed_array.append(entity.id);
            self.sparse_array[entity.id] = dense_index;
        }

        fn remove(self: *Self, entity: Entity) void {
            if (!self.contains(entity)) return;
            const dense_index = self.sparse_array[entity.id].?;
            const last_entity = self.packed_array.getLast();
            _ = self.packed_array.swapRemove(dense_index);
            self.sparse_array[last_entity] = dense_index;
            self.sparse_array[entity.id] = null;
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

    const e1 = Entity.init(1);
    const e2 = Entity.init(2);
    const e3 = Entity.init(5);

    // Test initial state
    try std.testing.expect(!sparseSet.contains(e1));

    // Test insert
    try sparseSet.insert(e1, .{ .value = 10 });
    try sparseSet.insert(e2, .{ .value = 20 });
    try std.testing.expect(sparseSet.contains(e1));
    try std.testing.expect(sparseSet.contains(e2));
    try std.testing.expect(!sparseSet.contains(e3));

    // Test component retrieval through indexTable
    if (sparseSet.get(e1)) |component| {
        try std.testing.expectEqual(@as(i32, 10), component.value);
    } else {
        try std.testing.expect(false); // Should not reach here
    }

    // Test updating existing component
    try sparseSet.insert(e1, .{ .value = 15 });
    if (sparseSet.get(e1)) |component| {
        try std.testing.expectEqual(@as(i32, 15), component.value);
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
