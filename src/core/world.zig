const std = @import("std");

const Entity = @import("entity.zig").Entity;

const sparse_set = @import("sparse_set.zig");
const SparseSet = sparse_set.SparseSet;
const AbstractSparseSet = sparse_set.AbstractSparseSet;

const SparseSetStorage = @import("storage.zig").SparseSetStorage;

pub const World = struct {
    sparseSetStorage: SparseSetStorage,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) World {
        return World{
            .sparseSetStorage = SparseSetStorage.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *World) void {
        self.sparseSetStorage.deinit();
    }

    /// Attaches a component to an entity.
    /// Note: The component is copied into the ECS storage.
    pub fn attachComponent(self: *World, entity: Entity, comptime C: type, component: C) !void {
        try self.sparseSetStorage.attachComponent(entity, C, component);
    }

    /// Attaches multiple component to an entity
    /// Note: The components must be compiletime-known.
    pub fn attachComponents(self: *World, entity: Entity, comptime types: anytype) !void {
        inline for (types) |component| {
            const C = @TypeOf(component);
            try self.attachComponent(entity, C, component);
        }
    }

    pub fn hasComponent(self: World, entity: Entity, comptime C: type) bool {
        return self.sparseSetStorage.hasComponent(entity, C);
    }

    pub fn getComponent(self: World, entity: Entity, comptime C: type) ?C {
        return self.sparseSetStorage.getComponent(entity, C);
    }
};

test "World basic operations" {
    // Test component types
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { value: i32 };

    // Initialize world
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Create entities
    const entity1 = Entity.init(1);
    const entity2 = Entity.init(2);

    // Test single component attachment
    try world.attachComponent(entity1, Position, .{ .x = 10, .y = 20 });
    try std.testing.expect(world.hasComponent(entity1, Position));
    try std.testing.expect(!world.hasComponent(entity1, Velocity));

    // Test component retrieval
    const pos = world.getComponent(entity1, Position) orelse unreachable;
    try std.testing.expectEqual(@as(f32, 10), pos.x);
    try std.testing.expectEqual(@as(f32, 20), pos.y);

    // Test multi-component attachment
    try world.attachComponents(entity2, .{
        Position{ .x = 5, .y = 15 },
        Velocity{ .dx = 1, .dy = 2 },
        Health{ .value = 100 },
    });

    try std.testing.expect(world.hasComponent(entity2, Position));
    try std.testing.expect(world.hasComponent(entity2, Velocity));
    try std.testing.expect(world.hasComponent(entity2, Health));

    // Test component values
    const pos2 = world.getComponent(entity2, Position) orelse unreachable;
    try std.testing.expectEqual(@as(f32, 5), pos2.x);
    try std.testing.expectEqual(@as(f32, 15), pos2.y);

    const vel2 = world.getComponent(entity2, Velocity) orelse unreachable;
    try std.testing.expectEqual(@as(f32, 1), vel2.dx);
    try std.testing.expectEqual(@as(f32, 2), vel2.dy);

    const health2 = world.getComponent(entity2, Health) orelse unreachable;
    try std.testing.expectEqual(@as(i32, 100), health2.value);

    // Test component updates
    try world.attachComponent(entity1, Position, .{ .x = 30, .y = 40 });
    const updatedPos = world.getComponent(entity1, Position) orelse unreachable;
    try std.testing.expectEqual(@as(f32, 30), updatedPos.x);
    try std.testing.expectEqual(@as(f32, 40), updatedPos.y);

    // Test non-existent component
    try std.testing.expect(!world.hasComponent(entity1, Health));
    try std.testing.expect(world.getComponent(entity1, Health) == null);
}
