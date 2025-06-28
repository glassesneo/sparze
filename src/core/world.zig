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

test "ECS running test" {
    const testing = std.testing;

    const Position = struct { x: i32, y: i32 };
    const Size = struct { h: i16, w: i16 };
    const Player = struct { hp: i32, mp: i16 };

    const allocator = testing.allocator;
    const entity1 = Entity.init(0);
    const entity2 = Entity.init(1);

    var world = World.init(allocator);
    defer world.deinit();

    try world.attachComponent(entity1, Position, Position{ .x = 10, .y = 20 });

    try world.attachComponents(entity2, .{
        Position{ .x = 5, .y = 15 },
        Size{ .h = 10, .w = 10 },
        Player{ .hp = 100, .mp = 50 },
    });

    if (world.getComponent(entity1, Position)) |c| {
        std.debug.print("Position: {any}\n", .{c});
    } else {
        std.debug.print("None!\n", .{});
    }

    if (world.getComponent(entity2, Player)) |c| {
        std.debug.print("Size: {any}\n", .{c});
    } else {
        std.debug.print("None!\n", .{});
    }
}
