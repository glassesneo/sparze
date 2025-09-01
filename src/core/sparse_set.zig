const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const entity_module = @import("entity.zig");
pub const max_entities = entity_module.max_entities;
const EntityRegistry = entity_module.EntityRegistry;
const Entity = entity_module.Entity;
const EntityIndex = entity_module.EntityIndex;
const EntityVersion = entity_module.EntityVersion;
const getIndex = entity_module.getIndex;
const getVersion = entity_module.getVersion;

pub const AbstractSparseSet = struct {
    // entities: []const Entity,
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        getEntities: *const fn (*anyopaque) []const Entity,
        getComponentsFn: *const fn (*anyopaque) *anyopaque,
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        containsFn: *const fn (*anyopaque, Entity) bool,
        removeFn: *const fn (*anyopaque, Entity) void,
    };

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime T: type) ?T {
        const component = self.vtable.getFn(self.instance, entity) orelse return null;
        const typed_ptr = castTo(T, component);
        return typed_ptr.*;
    }

    pub fn getEntities(self: *const AbstractSparseSet) []const Entity {
        return self.vtable.getEntities(self.instance);
    }

    pub fn getComponents(self: *const AbstractSparseSet, comptime T: type) []T {
        const components = self.vtable.getComponentsFn(self.instance);
        const typed_ptr = castTo([]T, components);
        return typed_ptr.*;
        // return @ptrCast(&components);
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
                    const page_idx = sparse_index / page_size;
                    const slot_idx = sparse_index % page_size;

                    const page = self.sparse_pages[page_idx] orelse return null;
                    const dense_index = page.slots[slot_idx] orelse return null;
                    return @ptrCast(&self.components.items[dense_index]);
                }
            }.get,
            .getEntities = struct {
                fn getEntities(ptr: *anyopaque) []const Entity {
                    const self = castTo(SparseSetType, ptr);
                    return self.packed_array.items;
                }
            }.getEntities,
            .getComponentsFn = struct {
                fn getComponents(ptr: *anyopaque) *anyopaque {
                    const self = castTo(SparseSetType, ptr);
                    return @ptrCast(&self.components.items);
                }
            }.getComponents,
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
            // .entities = instance.packed_array.items,
            .vtable = &vtable,
            .instance = instance,
        };
    }
};

// Pagination configuration
const page_size: u16 = 4096; // Entities per page
const max_pages: u16 = @intCast((@as(u32, max_entities) + @as(u32, page_size) - 1) / @as(u32, page_size));

/// A single page in the sparse array
const SparsePage = struct {
    slots: [page_size]?u16,

    fn init() SparsePage {
        return .{ .slots = [_]?u16{null} ** page_size };
    }
};

/// SparseSet creates a new sparse set type for the given component type.
/// Complexity: O(1) for type generation (compile-time).
pub fn SparseSet(comptime C: type) type {
    return struct {
        const Self = @This();
        pub const Component = C;
        allocator: Allocator,
        sparse_pages: [max_pages]?*SparsePage, // Paginated sparse array
        packed_array: ArrayList(Entity),
        components: ArrayList(Component),

        /// Initialize a new SparseSet with the given allocator.
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .sparse_pages = [_]?*SparsePage{null} ** max_pages,
                .packed_array = .{},
                .components = .{},
            };
        }

        /// Deinitialize the SparseSet, freeing internal buffers.
        pub fn deinit(self: *Self) void {
            // Free all allocated pages
            for (self.sparse_pages) |maybe_page| {
                const page = maybe_page orelse continue;
                self.allocator.destroy(page);
            }
            self.packed_array.deinit(self.allocator);
            self.components.deinit(self.allocator);
        }

        /// Get or create a sparse page for the given entity
        fn getOrCreatePage(self: *Self, entity: Entity) !*SparsePage {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;

            if (self.sparse_pages[page_idx]) |page| {
                return page;
            }

            // Allocate new page
            const new_page = try self.allocator.create(SparsePage);
            new_page.* = SparsePage.init();
            self.sparse_pages[page_idx] = new_page;
            return new_page;
        }

        /// Get sparse page if it exists
        fn getPage(self: *const Self, entity: Entity) ?*SparsePage {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            return self.sparse_pages[page_idx];
        }

        /// Check whether the set contains a component for the given entity.
        /// Complexity: O(1).
        pub fn contains(self: Self, entity: Entity) bool {
            return self.hasIndex(entity);
        }

        /// Retrieve the component associated with an entity, if present.
        /// Complexity: O(1).
        pub fn get(self: Self, entity: Entity) ?Component {
            if (!self.hasIndex(entity)) return null;

            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;
            const page = self.sparse_pages[page_idx].?; // hasIndex already checked this exists
            const dense_index = page.slots[slot_idx].?; // hasIndex already checked this exists

            return self.components.items[dense_index];
        }

        /// Insert or replace a component for the given entity.
        /// Complexity: O(1) amortized (ArrayList may reallocate).
        pub fn insert(self: *Self, entity: Entity, component: Component) !void {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;

            // Check if entity already has a component
            if (self.hasIndex(entity)) {
                const page = self.sparse_pages[page_idx].?;
                const dense_index = page.slots[slot_idx].?;
                self.components.items[dense_index] = component;
                self.packed_array.items[dense_index] = entity;
                return;
            }

            // Get or create the page for this entity
            const page = try self.getOrCreatePage(entity);

            // Add new component
            const dense_index: u16 = @intCast(self.components.items.len);
            try self.components.append(self.allocator, component);
            try self.packed_array.append(self.allocator, entity);
            page.slots[slot_idx] = dense_index;
        }

        /// Remove the component associated with an entity, if it exists.
        /// Complexity: O(1).
        pub fn remove(self: *Self, entity: Entity) void {
            if (!self.hasIndex(entity)) return;

            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;
            const page = self.sparse_pages[page_idx].?;
            const dense_index = page.slots[slot_idx].?;

            const last_dense: u16 = @intCast(self.components.items.len - 1);
            const last_entity = self.packed_array.items[last_dense];

            // Remove from packed (dense) entity array
            _ = self.packed_array.swapRemove(dense_index);
            self.components.items[dense_index] = self.components.items[last_dense];
            _ = self.components.swapRemove(last_dense);

            // Update sparse array for the entity that moved into the vacated slot
            const last_sparse_index = getIndex(last_entity);
            const last_page_idx = last_sparse_index / page_size;
            const last_slot_idx = last_sparse_index % page_size;
            const last_page = self.sparse_pages[last_page_idx].?;
            last_page.slots[last_slot_idx] = dense_index;

            // Clear the removed entity's entry
            page.slots[slot_idx] = null;
        }

        /// Internal helper: check whether an entity maps to a valid dense entry.
        /// Complexity: O(1).
        fn hasIndex(self: Self, entity: Entity) bool {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;

            const page = self.sparse_pages[page_idx] orelse return false;
            const dense_index = page.slots[slot_idx] orelse return false;

            if (dense_index >= self.packed_array.items.len) return false;
            return entity == self.packed_array.items[dense_index];
        }

        pub fn abstract(self: *Self) AbstractSparseSet {
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

    // Test component retrieval
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

test "SparseSet pagination with sparse entities" {
    const TestComp = struct { v: usize };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();

    // Create entities in different pages
    // Force entities into different pages by creating gaps
    var entities: [3]Entity = undefined;

    // Entity 0 (page 0)
    entities[0] = registry.create();

    // Skip to get entity in different page (around entity 4096)
    for (0..4096) |_| _ = registry.create();
    entities[1] = registry.create(); // This should be in page 1

    // Skip to get entity in another page (around entity 8192)
    for (0..4095) |_| _ = registry.create();
    entities[2] = registry.create(); // This should be in page 2

    // Insert components
    try set.insert(entities[0], .{ .v = 100 });
    try set.insert(entities[1], .{ .v = 200 });
    try set.insert(entities[2], .{ .v = 300 });

    // Verify all components are accessible
    try std.testing.expect(set.contains(entities[0]));
    try std.testing.expect(set.contains(entities[1]));
    try std.testing.expect(set.contains(entities[2]));

    try std.testing.expectEqual(@as(usize, 100), set.get(entities[0]).?.v);
    try std.testing.expectEqual(@as(usize, 200), set.get(entities[1]).?.v);
    try std.testing.expectEqual(@as(usize, 300), set.get(entities[2]).?.v);

    // Remove middle entity and verify others remain
    set.remove(entities[1]);
    try std.testing.expect(set.contains(entities[0]));
    try std.testing.expect(!set.contains(entities[1]));
    try std.testing.expect(set.contains(entities[2]));

    try std.testing.expectEqual(@as(usize, 100), set.get(entities[0]).?.v);
    try std.testing.expectEqual(@as(usize, 300), set.get(entities[2]).?.v);
}

test "SparseSet entity version validation" {
    const TestComp = struct { v: usize };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();

    // Create two entities with same index but different versions
    const e1 = registry.create();
    registry.destroy(e1);
    const e2 = registry.create(); // Reuses same index with incremented version

    try std.testing.expectEqual(getIndex(e1), getIndex(e2));
    try std.testing.expect(getVersion(e2) > getVersion(e1));

    // Add component to newer version
    try set.insert(e2, .{ .v = 42 });
    try std.testing.expect(set.contains(e2));

    // Stale reference should not match newer version
    try std.testing.expect(!set.contains(e1));
    try std.testing.expect(set.get(e1) == null);

    // Only newer version should have component
    try std.testing.expectEqual(@as(usize, 42), set.get(e2).?.v);
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
