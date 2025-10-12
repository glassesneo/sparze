// A practical example showing a simple movement system using groups.
// Run with `zig build run-examples` after adding to the build.zig examples list.

const std = @import("std");
const sparze = @import("sparze");

// Component definitions used in this example
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

// Define World type
const World = sparze.World(struct { Position, Velocity });

// Declare group type constant for better readability and maintainability
const MovementGroup = struct { Position, Velocity };

// Define system as plain function
fn movementSystem(group: sparze.Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize world
    var world = World.init(allocator);
    defer world.deinit();

    // Create a full‑owning group so iteration is fast.
    try world.createGroup(MovementGroup);

    // Create a couple of entities.
    const e1 = world.createEntity();
    try world.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(e1, Velocity, .{ .x = 1.0, .y = 2.0 });

    const e2 = world.createEntity();
    try world.addComponent(e2, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addComponent(e2, Velocity, .{ .x = -0.5, .y = 0.0 });

    // Run the system for a few frames.
    for (0..3) |_| {
        try world.runSystem(movementSystem);
    }

    // Print the final positions.
    const p1 = world.getComponent(e1, Position).?;
    const p2 = world.getComponent(e2, Position).?;
    std.debug.print("Entity 1 final position: ({d}, {d})\n", .{ p1.x, p1.y });
    std.debug.print("Entity 2 final position: ({d}, {d})\n", .{ p2.x, p2.y });
}
