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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return EntityManager{
            .next_id = 0,
            .free_ids = .init(allocator),
            .generations = .init(allocator),
            .entities = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntityManager) void {
        self.free_ids.deinit();
        self.generations.deinit();
        self.entities.deinit();
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

        try self.entities.append(entity);
        return entity;
    }

    pub fn destroy(self: *EntityManager, id: Entity.EntityId) !void {
        for (self.entities.items, 0..) |entity, i| {
            if (entity.id == id) {
                _ = self.entities.orderedRemove(i);
                try self.free_ids.append(id);
                break;
            }
        }
    }

    pub fn exists(self: *const EntityManager, entity: Entity) bool {
        return for (self.entities.items) |e| {
            if (e.id == entity.id and e.generation == entity.generation) {
                break true;
            }
        } else false;
    }

    pub fn count(self: *const EntityManager) usize {
        return self.entities.items.len;
    }

    pub fn getEntityById(self: *const EntityManager, id: Entity.EntityId) ?Entity {
        return for (self.entities.items) |entity| {
            if (entity.id == id) {
                break entity;
            }
        } else null;
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
