const std = @import("std");

pub const Entity = struct {
    id: usize,
    pub fn init(id: usize) Entity {
        return Entity{ .id = id };
    }
};

pub const EntityManager = struct {
    next_id: usize,
    entities: std.ArrayList(Entity),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return EntityManager{
            .next_id = 0,
            .entities = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntityManager) void {
        self.entities.deinit();
    }

    pub fn create(self: *EntityManager) Entity {
        const entity = Entity.init(self.next_id);
        self.next_id += 1;
        self.entities.append(entity) catch unreachable;
        return entity;
    }

    pub fn destroy(self: *EntityManager, entity: Entity) void {
        // Find and remove the entity with the matching ID
        var i: usize = 0;
        while (i < self.entities.items.len) : (i += 1) {
            if (self.entities.items[i].id == entity.id) {
                _ = self.entities.orderedRemove(i);
                break;
            }
        }
    }

    pub fn exists(self: *const EntityManager, entity: Entity) bool {
        for (self.entities.items) |e| {
            if (e.id == entity.id) {
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const EntityManager) usize {
        return self.entities.items.len;
    }

    pub fn getEntityById(self: *const EntityManager, id: usize) ?Entity {
        for (self.entities.items) |entity| {
            if (entity.id == id) {
                return entity;
            }
        }
        return null;
    }

    pub fn getAllEntities(self: *const EntityManager) []const Entity {
        return self.entities.items;
    }
};

test "Entity basics" {
    const e1 = Entity.init(123);
    try std.testing.expectEqual(@as(usize, 123), e1.id);
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
    const e1 = manager.create();
    const e2 = manager.create();
    try std.testing.expectEqual(@as(usize, 0), e1.id);
    try std.testing.expectEqual(@as(usize, 1), e2.id);
    try std.testing.expectEqual(@as(usize, 2), manager.count());

    // Test exists check
    try std.testing.expect(manager.exists(e1));
    try std.testing.expect(manager.exists(e2));
    try std.testing.expect(!manager.exists(Entity.init(99)));

    // Test get by ID
    try std.testing.expectEqual(e1.id, manager.getEntityById(0).?.id);
    try std.testing.expect(manager.getEntityById(99) == null);

    // Test getAllEntities
    const all = manager.getAllEntities();
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(e1.id, all[0].id);
    try std.testing.expectEqual(e2.id, all[1].id);

    // Test entity destruction
    manager.destroy(e1);
    try std.testing.expect(!manager.exists(e1));
    try std.testing.expectEqual(@as(usize, 1), manager.count());

    // Test getEntityById after destruction
    try std.testing.expect(manager.getEntityById(0) == null);

    // Test destroying non-existent entity (should not crash)
    manager.destroy(Entity.init(99));
    try std.testing.expectEqual(@as(usize, 1), manager.count());
}
