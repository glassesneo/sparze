const std = @import("std");
const sparze = @import("sparze");

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = sparze.DynamicWorld.init(allocator);
    defer world.deinit();

    // Create sparse sets
    var position_sparse_set = sparze.SparseSet(Position).init(allocator);
    defer position_sparse_set.deinit();
    var velocity_sparse_set = sparze.SparseSet(Velocity).init(allocator);
    defer velocity_sparse_set.deinit();

    // Register components
    try world.registerComponent(Position, &position_sparse_set);
    try world.registerComponent(Velocity, &velocity_sparse_set);

    // Create entities with components
    const e1 = world.createEntity();
    const e2 = world.createEntity();
    const e3 = world.createEntity();

    try world.addComponent(e1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(e2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(e3, Position, .{ .x = 50.0, .y = 60.0 });

    try world.addComponent(e1, Velocity, .{ .x = 1.0, .y = 2.0 });
    try world.addComponent(e3, Velocity, .{ .x = 3.0, .y = 4.0 });

    // Create a group for entities with both Position and Velocity
    const MovingEntitiesGroup = struct { Position, Velocity };
    try world.createGroup(MovingEntitiesGroup);

    std.debug.print("Created group for MovingEntitiesGroup\n", .{});

    // Get entities in the group (fast iteration)
    if (world.getGroupEntities(MovingEntitiesGroup)) |entities| {
        std.debug.print("Group has {} entities\n", .{entities.len});
        for (entities) |entity| {
            std.debug.print("Entity in group: {}\n", .{entity});
        }
    }

    // Get components from the group (fast iteration)
    if (world.getGroupComponents(MovingEntitiesGroup, Position)) |positions| {
        std.debug.print("Positions in group:\n", .{});
        for (positions) |pos| {
            std.debug.print("  ({d}, {d})\n", .{ pos.x, pos.y });
        }
    }

    if (world.getGroupComponents(MovingEntitiesGroup, Velocity)) |velocities| {
        std.debug.print("Velocities in group:\n", .{});
        for (velocities) |vel| {
            std.debug.print("  ({d}, {d})\n", .{ vel.x, vel.y });
        }
    }

    // Add velocity to e2 - it should join the group automatically
    try world.addComponent(e2, Velocity, .{ .x = 5.0, .y = 6.0 });

    std.debug.print("\nAfter adding velocity to e2:\n", .{});
    if (world.getGroupEntities(MovingEntitiesGroup)) |entities| {
        std.debug.print("Group now has {} entities\n", .{entities.len});
        for (entities) |entity| {
            std.debug.print("Entity in group: {}\n", .{entity});
        }
    }

    // Remove velocity from e1 - it should leave the group automatically
    world.removeComponent(e1, Velocity);

    std.debug.print("\nAfter removing velocity from e1:\n", .{});
    if (world.getGroupEntities(MovingEntitiesGroup)) |entities| {
        std.debug.print("Group now has {} entities\n", .{entities.len});
        for (entities) |entity| {
            std.debug.print("Entity in group: {}\n", .{entity});
        }
    }
}
