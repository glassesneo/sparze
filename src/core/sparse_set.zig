const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const entity_module = @import("entity.zig");
pub const entity_id_limit = entity_module.entity_id_limit;
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;
const getIndex = entity_module.getIndex;

pub const AbstractSparseSet = struct {
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        containsFn: *const fn (*anyopaque, Entity) bool,
        removeFn: *const fn (*anyopaque, Entity) void,
    };

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime T: type) ?T {
        const component = self.vtable.getFn(self.instance, entity) orelse return null;
        const typed_ptr = castTo(T, component);
        return typed_ptr.*;
    }

    pub fn insert(self: *const AbstractSparseSet, entity: Entity, component: *anyopaque) !void {
        return try self.vtable.insertFn(self.instance, entity, component);
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

    pub fn init(comptime Component: type, instance: *SparseSet(Component)) AbstractSparseSet {
        const SparseSetType = SparseSet(Component);
        const vtable = comptime VTable{
            .getFn = struct {
                fn get(ptr: *anyopaque, entity: Entity) ?*anyopaque {
                    const self = castTo(SparseSetType, ptr);
                    const sparse_index = getIndex(entity);
                    const dense_index = self.sparse_array[sparse_index] orelse return null;
                    return @ptrCast(&self.components.items[dense_index]);
                }
            }.get,
            .insertFn = struct {
                fn insert(ptr: *anyopaque, entity: Entity, component_ptr: *anyopaque) !void {
                    const self = castTo(SparseSetType, ptr);
                    const component = castTo(Component, component_ptr);
                    try self.insert(entity, component.*);
                }
            }.insert,
            .containsFn = struct {
                fn contains(ptr: *anyopaque, entity: Entity) bool {
                    const self = castTo(SparseSetType, ptr);
                    return self.contains(entity);
                }
            }.contains,
            .removeFn = struct {
                fn remove(ptr: *anyopaque, entity: Entity) void {
                    const self = castTo(SparseSetType, ptr);
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

/// SparseSet creates a new sparse set type for the given component type.
/// Complexity: O(1) for type generation (compile-time).
pub fn SparseSet(comptime Component: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        sparse_array: [entity_id_limit]?u16, // index: entity id, element: index of components
        packed_array: ArrayList(u16), // element: entity id
        components: ArrayList(Component),

        /// Initialize a new SparseSet with the given allocator.
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .sparse_array = [_]?u16{null} ** entity_id_limit,
                .packed_array = .{},
                .components = .{},
            };
        }

        /// Deinitialize the SparseSet, freeing internal buffers.
        pub fn deinit(self: *Self) void {
            self.packed_array.deinit(self.allocator);
            self.components.deinit(self.allocator);
        }

        /// Check whether the set contains a component for the given entity.
        /// Complexity: O(1).
        fn contains(self: Self, entity: Entity) bool {
            const sparse_index = getIndex(entity);
            return self.hasIndex(sparse_index);
        }

        /// Retrieve the component associated with an entity, if present.
        /// Complexity: O(1).
        fn get(self: Self, entity: Entity) ?Component {
            const sparse_index = getIndex(entity);
            if (!self.hasIndex(sparse_index)) return null;
            const dense_index = self.sparse_array[sparse_index].?;
            return self.components.items[dense_index];
        }

        /// Insert or replace a component for the given entity.
        /// Complexity: O(1) amortized (ArrayList may reallocate).
        fn insert(self: *Self, entity: Entity, component: Component) !void {
            const sparse_index = getIndex(entity);
            if (self.hasIndex(sparse_index)) {
                const dense_index = self.sparse_array[sparse_index].?;
                self.components.items[dense_index] = component;
                self.packed_array.items[dense_index] = sparse_index;
                return;
            }

            const dense_index: u16 = @intCast(self.components.items.len);
            try self.components.append(self.allocator, component);
            try self.packed_array.append(self.allocator, sparse_index);
            self.sparse_array[sparse_index] = dense_index;
        }

        /// Remove the component associated with an entity, if it exists.
        /// Complexity: O(1).
        fn remove(self: *Self, entity: Entity) void {
            const sparse_index = getIndex(entity);
            if (!self.hasIndex(sparse_index)) return;
            const dense_index = self.sparse_array[sparse_index].?;
            const last_dense: u16 = @intCast(self.components.items.len - 1);
            const last_entity = self.packed_array.items[last_dense];
            // Remove from packed (dense) entity array
            _ = self.packed_array.swapRemove(dense_index);
            // Remove component, preserving order via swap if not last
            if (dense_index != last_dense) {
                self.components.items[dense_index] = self.components.items[last_dense];
            }
            _ = self.components.swapRemove(last_dense);
            // Update sparse array for the entity that moved into the vacated slot
            self.sparse_array[last_entity] = dense_index;
            // Clear the removed entity's entry
            self.sparse_array[sparse_index] = null;
        }

        /// Internal helper: check whether a sparse index maps to a valid dense entry.
        /// Complexity: O(1).
        fn hasIndex(self: Self, index: u16) bool {
            if (index >= entity_id_limit) return false;
            const dense_index = self.sparse_array[index] orelse return false;
            if (dense_index >= self.packed_array.items.len) return false;
            return index == self.packed_array.items[dense_index];
        }

        fn abstract(self: *Self) AbstractSparseSet {
            return AbstractSparseSet.init(Component, self);
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

    var registry = EntityRegistry.init();

    var sparseSet = SparseSet(TestComponent).init(allocator);
    defer sparseSet.deinit();

    const e1 = registry.create();
    const e2 = registry.create();
    const e3 = registry.create();

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

test "SparseSet removal consistency" {
    const TestComp = struct { v: usize };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();
    const total = 10;
    var ids = [_]Entity{undefined} ** total;
    for (0..total) |i| {
        ids[i] = registry.create();
        try set.insert(ids[i], .{ .v = i });
    }

    const mid = ids[5];
    set.remove(mid);
    try std.testing.expect(!set.contains(mid));

    for (0..total) |i| {
        if (i == 5) continue;
        const comp = set.get(ids[i]).?;
        try std.testing.expectEqual(@as(usize, i), comp.v);
    }

    try std.testing.expectEqual(@as(usize, total - 1), set.components.items.len);
}

test "AbstractSparseSet dynamic dispatch" {
    const TestComp = struct { v: usize };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    // Concrete API works
    var registry = EntityRegistry.init();
    const entity = registry.create();
    try set.insert(entity, .{ .v = 42 });
    try std.testing.expect(set.contains(entity));
    try std.testing.expectEqual(@as(usize, 42), set.get(entity).?.v);

    // Convert to abstract interface
    const abstract_set = set.abstract();

    // Dynamic get/contains match concrete behavior
    try std.testing.expect(abstract_set.contains(entity));
    const component = abstract_set.get(entity, TestComp).?;
    try std.testing.expectEqual(@as(usize, 42), component.v);

    // Remove via abstract interface and verify
    abstract_set.remove(entity);
    try std.testing.expect(!abstract_set.contains(entity));
    try std.testing.expect(abstract_set.get(entity, TestComp) == null);
}
