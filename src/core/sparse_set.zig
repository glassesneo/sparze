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

/// Group information for sparse sets
pub const GroupInfo = struct {
    size: u32 = 0, // Number of entities in the group at the start of packed array

    pub fn empty(self: GroupInfo) bool {
        return self.size == 0;
    }
};

pub const AbstractSparseSet = struct {
    // entities: []const Entity,
    vtable: *const VTable,
    instance: *anyopaque,
    const VTable = struct {
        getFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        getPtrFn: *const fn (*anyopaque, Entity) ?*const anyopaque,
        getPtrMutFn: *const fn (*anyopaque, Entity) ?*anyopaque,
        getEntities: *const fn (*anyopaque) []const Entity,
        getComponentsFn: *const fn (*anyopaque) *anyopaque,
        insertFn: *const fn (*anyopaque, Entity, *anyopaque) anyerror!void,
        containsFn: *const fn (*anyopaque, Entity) bool,
        removeFn: *const fn (*anyopaque, Entity) void,
        moveToGroupFn: *const fn (*anyopaque, Entity) void,
        moveFromGroupFn: *const fn (*anyopaque, Entity) void,
        getGroupSizeFn: *const fn (*anyopaque) u32,
        getGroupEntitiesFn: *const fn (*anyopaque) []const Entity,
    };

    pub fn get(self: *const AbstractSparseSet, entity: Entity, comptime C: type) ?C {
        const component = self.vtable.getFn(self.instance, entity) orelse return null;
        const typed_ptr = castTo(C, component);
        return typed_ptr.*;
    }

    pub fn getPtr(self: *const AbstractSparseSet, entity: Entity, comptime C: type) ?*const C {
        const component = self.vtable.getPtrFn(self.instance, entity) orelse return null;
        const typed_ptr: *const C = @ptrCast(@alignCast(component));
        return typed_ptr;
    }

    pub fn getPtrMut(self: *const AbstractSparseSet, entity: Entity, comptime C: type) ?*C {
        const component = self.vtable.getPtrMutFn(self.instance, entity) orelse return null;
        const typed_ptr = castTo(C, component);
        return typed_ptr;
    }

    pub fn getEntities(self: *const AbstractSparseSet) []const Entity {
        return self.vtable.getEntities(self.instance);
    }

    pub fn getComponents(self: *const AbstractSparseSet, comptime C: type) []C {
        const components = self.vtable.getComponentsFn(self.instance);
        const typed_ptr = castTo([]C, components);
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

    pub fn moveToGroup(self: *const AbstractSparseSet, entity: Entity) void {
        return self.vtable.moveToGroupFn(self.instance, entity);
    }

    pub fn moveFromGroup(self: *const AbstractSparseSet, entity: Entity) void {
        return self.vtable.moveFromGroupFn(self.instance, entity);
    }

    pub fn getGroupSize(self: *const AbstractSparseSet) u32 {
        return self.vtable.getGroupSizeFn(self.instance);
    }

    pub fn getGroupEntities(self: *const AbstractSparseSet) []const Entity {
        return self.vtable.getGroupEntitiesFn(self.instance);
    }

    pub fn incarnate(self: *const AbstractSparseSet, comptime C: type) *SparseSet(C) {
        return castTo(SparseSet(C), self.instance);
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
            .getPtrFn = struct {
                fn getPtr(ptr: *anyopaque, entity: Entity) ?*const anyopaque {
                    const self = castTo(SparseSetType, ptr);
                    return self.getPtr(entity);
                }
            }.getPtr,
            .getPtrMutFn = struct {
                fn getPtrMut(ptr: *anyopaque, entity: Entity) ?*anyopaque {
                    const self = castTo(SparseSetType, ptr);
                    return self.getPtrMut(entity);
                }
            }.getPtrMut,
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
            .moveToGroupFn = struct {
                fn moveToGroup(ptr: *anyopaque, entity: Entity) void {
                    const self = castTo(SparseSetType, ptr);
                    self.moveToGroup(entity);
                }
            }.moveToGroup,
            .moveFromGroupFn = struct {
                fn moveFromGroup(ptr: *anyopaque, entity: Entity) void {
                    const self = castTo(SparseSetType, ptr);
                    self.moveFromGroup(entity);
                }
            }.moveFromGroup,
            .getGroupSizeFn = struct {
                fn getGroupSize(ptr: *anyopaque) u32 {
                    const self = castTo(SparseSetType, ptr);
                    return self.group_info.size;
                }
            }.getGroupSize,
            .getGroupEntitiesFn = struct {
                fn getGroupEntities(ptr: *anyopaque) []const Entity {
                    const self = castTo(SparseSetType, ptr);
                    return self.getGroupEntities();
                }
            }.getGroupEntities,
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
        group_info: GroupInfo = .{},

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
            const ptr = self.getPtr(entity) orelse return null;
            return ptr.*;
        }

        /// Retrieve a pointer to the component associated with an entity, if present.
        /// Complexity: O(1).
        pub fn getPtr(self: *const Self, entity: Entity) ?*const Component {
            if (!self.hasIndex(entity)) return null;

            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;
            const page = self.sparse_pages[page_idx].?;
            const dense_index = page.slots[slot_idx].?;

            return &self.components.items[dense_index];
        }

        /// Retrieve a mutable pointer to the component associated with an entity, if present.
        /// Complexity: O(1).
        pub fn getPtrMut(self: *Self, entity: Entity) ?*Component {
            if (!self.hasIndex(entity)) return null;

            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;
            const page = self.sparse_pages[page_idx].?;
            const dense_index = page.slots[slot_idx].?;

            return &self.components.items[dense_index];
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

        /// Move entity to group area (at the beginning of packed array)
        pub fn moveToGroup(self: *Self, entity: Entity) void {
            if (!self.contains(entity)) return;

            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;
            const page = self.sparse_pages[page_idx].?;
            const dense_index = page.slots[slot_idx].?;

            // If already in group area, nothing to do
            if (dense_index < self.group_info.size) return;

            // Swap with first element outside group
            const swap_index: u16 = @intCast(self.group_info.size);
            self.swapElements(dense_index, swap_index);
            self.group_info.size += 1;
        }

        /// Move entity out of group area
        pub fn moveFromGroup(self: *Self, entity: Entity) void {
            if (!self.contains(entity)) return;

            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;
            const page = self.sparse_pages[page_idx].?;
            const dense_index = page.slots[slot_idx].?;

            // If not in group area, nothing to do
            if (dense_index >= self.group_info.size) return;

            // Swap with last element in group
            const swap_index: u16 = @intCast(self.group_info.size - 1);
            self.swapElements(dense_index, swap_index);
            self.group_info.size -= 1;
        }

        fn swapElements(self: *Self, idx1: u16, idx2: u16) void {
            if (idx1 == idx2) return;

            // Swap in packed array
            const entity1 = self.packed_array.items[idx1];
            const entity2 = self.packed_array.items[idx2];
            self.packed_array.items[idx1] = entity2;
            self.packed_array.items[idx2] = entity1;

            // Swap components
            const temp = self.components.items[idx1];
            self.components.items[idx1] = self.components.items[idx2];
            self.components.items[idx2] = temp;

            // Update sparse arrays
            self.updateSparseIndex(entity1, idx2);
            self.updateSparseIndex(entity2, idx1);
        }

        fn updateSparseIndex(self: *Self, entity: Entity, new_index: EntityIndex) void {
            const sparse_index = getIndex(entity);
            const page_idx = sparse_index / page_size;
            const slot_idx = sparse_index % page_size;
            const page = self.sparse_pages[page_idx].?;
            page.slots[slot_idx] = new_index;
        }

        /// Get entities in group (at start of packed array)
        pub fn getGroupEntities(self: *const Self) []const Entity {
            return self.packed_array.items[0..self.group_info.size];
        }

        /// Get components in group (at start of components array)
        pub fn getGroupComponents(self: *const Self) []const Component {
            return self.components.items[0..self.group_info.size];
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

test "SparseSet pointer access methods" {
    const TestComp = struct { value: i32, count: u32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();
    const entity = registry.create();

    // Test getPtr/getPtrMut with non-existent entity
    try std.testing.expect(set.getPtr(entity) == null);
    try std.testing.expect(set.getPtrMut(entity) == null);

    // Insert component and test immutable pointer access
    try set.insert(entity, .{ .value = 100, .count = 5 });

    const const_ptr = set.getPtr(entity).?;
    try std.testing.expectEqual(@as(i32, 100), const_ptr.value);
    try std.testing.expectEqual(@as(u32, 5), const_ptr.count);

    // Test mutable pointer access and modification
    const mut_ptr = set.getPtrMut(entity).?;
    mut_ptr.value = 200;
    mut_ptr.count = 10;

    // Verify changes through value access
    const component = set.get(entity).?;
    try std.testing.expectEqual(@as(i32, 200), component.value);
    try std.testing.expectEqual(@as(u32, 10), component.count);

    // Verify changes persist through pointer access
    const verify_ptr = set.getPtr(entity).?;
    try std.testing.expectEqual(@as(i32, 200), verify_ptr.value);
    try std.testing.expectEqual(@as(u32, 10), verify_ptr.count);
}

test "AbstractSparseSet pointer access methods" {
    const TestComp = struct { x: f32, y: f32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();
    const entity1 = registry.create();
    const entity2 = registry.create();

    const abstract_set = set.abstract();

    // Test pointer access on empty set
    try std.testing.expect(abstract_set.getPtr(entity1, TestComp) == null);
    try std.testing.expect(abstract_set.getPtrMut(entity1, TestComp) == null);

    // Insert components for both entities
    try set.insert(entity1, .{ .x = 1.5, .y = 2.5 });
    try set.insert(entity2, .{ .x = 3.5, .y = 4.5 });

    // Test immutable pointer access through abstract interface
    const ptr1 = abstract_set.getPtr(entity1, TestComp).?;
    const ptr2 = abstract_set.getPtr(entity2, TestComp).?;

    try std.testing.expectEqual(@as(f32, 1.5), ptr1.x);
    try std.testing.expectEqual(@as(f32, 2.5), ptr1.y);
    try std.testing.expectEqual(@as(f32, 3.5), ptr2.x);
    try std.testing.expectEqual(@as(f32, 4.5), ptr2.y);

    // Test mutable pointer access and modification through abstract interface
    const mut_ptr1 = abstract_set.getPtrMut(entity1, TestComp).?;
    mut_ptr1.x = 10.0;
    mut_ptr1.y = 20.0;

    // Verify changes through concrete interface
    const updated = set.get(entity1).?;
    try std.testing.expectEqual(@as(f32, 10.0), updated.x);
    try std.testing.expectEqual(@as(f32, 20.0), updated.y);

    // Verify entity2 was not affected
    const unchanged = set.get(entity2).?;
    try std.testing.expectEqual(@as(f32, 3.5), unchanged.x);
    try std.testing.expectEqual(@as(f32, 4.5), unchanged.y);
}

test "SparseSet pointer consistency across operations" {
    const TestComp = struct { id: u64 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set = SparseSet(TestComp).init(allocator);
    defer set.deinit();

    var registry = EntityRegistry.init();
    const entity1 = registry.create();
    const entity2 = registry.create();
    const entity3 = registry.create();

    // Insert components
    try set.insert(entity1, .{ .id = 111 });
    try set.insert(entity2, .{ .id = 222 });
    try set.insert(entity3, .{ .id = 333 });

    // Get pointers before removal
    const ptr1_before = set.getPtr(entity1).?;
    const ptr3_before = set.getPtr(entity3).?;

    try std.testing.expectEqual(@as(u64, 111), ptr1_before.id);
    try std.testing.expectEqual(@as(u64, 333), ptr3_before.id);

    // Remove middle entity (triggers swap-remove)
    set.remove(entity2);

    // Verify pointers to remaining entities are still valid and correct
    const ptr1_after = set.getPtr(entity1).?;
    const ptr3_after = set.getPtr(entity3).?;

    try std.testing.expectEqual(@as(u64, 111), ptr1_after.id);
    try std.testing.expectEqual(@as(u64, 333), ptr3_after.id);

    // Verify removed entity returns null
    try std.testing.expect(set.getPtr(entity2) == null);
    try std.testing.expect(set.getPtrMut(entity2) == null);
}

test "AbstractSparseSet pointer type safety" {
    const CompA = struct { a: i32 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var set_a = SparseSet(CompA).init(allocator);
    defer set_a.deinit();

    var registry = EntityRegistry.init();
    const entity = registry.create();

    try set_a.insert(entity, .{ .a = 42 });

    const abstract_set = set_a.abstract();

    // Correct type access should work
    const ptr_a = abstract_set.getPtr(entity, CompA).?;
    try std.testing.expectEqual(@as(i32, 42), ptr_a.a);

    const mut_ptr_a = abstract_set.getPtrMut(entity, CompA).?;
    mut_ptr_a.a = 100;
    try std.testing.expectEqual(@as(i32, 100), set_a.get(entity).?.a);
}
