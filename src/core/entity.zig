const std = @import("std");

pub const Entity = struct {
    pub const EntityId = usize;

    id: EntityId,
    generation: usize,
    pub fn init(id: EntityId, generation: usize) Entity {
        return Entity{ .id = id, .generation = generation };
    }
};

pub const EntityManager = struct {
    next_id: Entity.EntityId,
    free_ids: std.ArrayList(Entity.EntityId),
    generations: std.ArrayList(usize),
    entities: std.ArrayList(Entity),
    /// Maps entity IDs to their indices in the entities array for O(1) access.
    /// Invariant: For each entry (id, index), entities.items[index].id == id
    /// Must be updated whenever entities array is modified.
    entity_indices: std.AutoHashMap(Entity.EntityId, usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return EntityManager{
            .next_id = 0,
            .free_ids = .init(allocator),
            .generations = .init(allocator),
            .entities = .init(allocator),
            .entity_indices = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntityManager) void {
        self.free_ids.deinit();
        self.generations.deinit();
        self.entities.deinit();
        self.entity_indices.deinit();
    }

    pub fn create(self: *EntityManager) !Entity {
        const entity = if (self.free_ids.pop()) |id| recycle: {
            self.generations.items[id] += 1;
            break :recycle Entity.init(id, self.generations.items[id]);
        } else generate: {
            defer self.next_id += 1;
            try self.generations.append(0);
            break :generate Entity.init(self.next_id, 0);
        };

        const index = self.entities.items.len;
        try self.entities.append(entity);
        try self.entity_indices.put(entity.id, index);
        return entity;
    }

    pub fn destroy(self: *EntityManager, id: Entity.EntityId) !void {
        if (self.entity_indices.get(id)) |index| {
            // Use swapRemove for O(1) removal
            _ = self.entities.swapRemove(index);
            _ = self.entity_indices.remove(id);
            try self.free_ids.append(id);

            // Update lookup table for the swapped entity (if any)
            if (index < self.entities.items.len) {
                const swapped_entity = self.entities.items[index];
                try self.entity_indices.put(swapped_entity.id, index);
            }
        }
    }

    pub fn exists(self: *const EntityManager, entity: Entity) bool {
        if (self.entity_indices.get(entity.id)) |index| {
            const stored_entity = self.entities.items[index];
            return stored_entity.generation == entity.generation;
        }
        return false;
    }

    pub fn count(self: *const EntityManager) usize {
        return self.entities.items.len;
    }

    pub fn getEntityById(self: *const EntityManager, id: Entity.EntityId) ?Entity {
        if (self.entity_indices.get(id)) |index| {
            return self.entities.items[index];
        }
        return null;
    }

    pub fn getAllEntities(self: *const EntityManager) []const Entity {
        return self.entities.items;
    }
};

test "Entity basics" {
    const e1 = Entity.init(123, 0);
    try std.testing.expectEqual(@as(Entity.EntityId, 123), e1.id);
}

test "EntityManager operations" {
    // Setup
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var manager = EntityManager.init(arena.allocator());
    defer manager.deinit();

    // Test initial state
    try std.testing.expectEqual(@as(usize, 0), manager.count());

    // Test entity creation
    const e1 = try manager.create();
    const e2 = try manager.create();
    try std.testing.expectEqual(@as(Entity.EntityId, 0), e1.id);
    try std.testing.expectEqual(@as(Entity.EntityId, 1), e2.id);
    try std.testing.expectEqual(@as(usize, 2), manager.count());

    // Test exists check
    try std.testing.expect(manager.exists(e1));
    try std.testing.expect(manager.exists(e2));
    try std.testing.expect(!manager.exists(Entity.init(99, 0)));

    // Test get by ID
    try std.testing.expectEqual(e1.id, manager.getEntityById(0).?.id);
    try std.testing.expect(manager.getEntityById(99) == null);

    // Test getAllEntities
    const all = manager.getAllEntities();
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(e1.id, all[0].id);
    try std.testing.expectEqual(e2.id, all[1].id);

    // Test entity destruction
    try manager.destroy(e1.id);
    try std.testing.expect(!manager.exists(e1));
    try std.testing.expectEqual(@as(usize, 1), manager.count());

    // Test getEntityById after destruction
    try std.testing.expect(manager.getEntityById(0) == null);

    // Test destroying non-existent entity (should not crash)
    try manager.destroy(Entity.init(99, 0).id);
    try std.testing.expectEqual(@as(usize, 1), manager.count());
}

test "EntityManager recycles entity IDs after destruction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var manager = EntityManager.init(arena.allocator());
    defer manager.deinit();

    const e1 = try manager.create();
    const e2 = try manager.create();
    try manager.destroy(e1.id);
    const e3 = try manager.create();
    try std.testing.expectEqual(e1.id, e3.id); // ID should be recycled
    try std.testing.expect(manager.exists(e3));
    try std.testing.expect(!manager.exists(e1));
    try std.testing.expect(manager.exists(e2));
}

// Test that validates O(1) performance characteristics and correctness at scale.
// This test ensures that operations remain efficient even with many entities,
// and verifies that the entity_indices invariant is maintained.
test "EntityManager O(1) operations performance and correctness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var manager = EntityManager.init(arena.allocator());
    defer manager.deinit();

    // Test with a substantial number of entities to validate scalability
    const num_entities = 1000;
    var entities: [num_entities]Entity = undefined;

    // Test O(1) creation and immediate lookup validation
    for (0..num_entities) |i| {
        entities[i] = try manager.create();

        // Validate entity_indices invariant: entities[index].id == id
        if (manager.entity_indices.get(entities[i].id)) |index| {
            try std.testing.expectEqual(entities[i].id, manager.entities.items[index].id);
        } else {
            try std.testing.expect(false); // entity_indices should contain the new entity
        }

        // Validate O(1) operations work correctly
        try std.testing.expect(manager.exists(entities[i]));
        try std.testing.expectEqual(entities[i].id, manager.getEntityById(entities[i].id).?.id);
    }

    try std.testing.expectEqual(@as(usize, num_entities), manager.count());
    try std.testing.expectEqual(@as(usize, num_entities), manager.entity_indices.count());

    // Test O(1) destruction with invariant validation
    for (0..num_entities / 2) |i| {
        const entity_id = entities[i].id;
        try manager.destroy(entity_id);

        // Validate entity is properly removed
        try std.testing.expect(!manager.exists(entities[i]));
        try std.testing.expect(manager.getEntityById(entity_id) == null);
        try std.testing.expect(!manager.entity_indices.contains(entity_id));
    }

    try std.testing.expectEqual(@as(usize, num_entities / 2), manager.count());
    try std.testing.expectEqual(@as(usize, num_entities / 2), manager.entity_indices.count());

    // Validate entity_indices invariant still holds for remaining entities
    var indices_iter = manager.entity_indices.iterator();
    while (indices_iter.next()) |entry| {
        const entity_id = entry.key_ptr.*;
        const index = entry.value_ptr.*;
        try std.testing.expectEqual(entity_id, manager.entities.items[index].id);
    }
}
