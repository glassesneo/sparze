// A practical example showing a simple movement system using groups.
// Run with `zig build run-examples` after adding to the build.zig examples list.

const std = @import("std");
const sparze = @import("sparze");

// Component definitions used in this example
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

// Define World type
const World = sparze.World(struct { Position, Velocity }, struct {}, struct {});

// Declare group type constant for better readability and maintainability
const MovementGroup = struct { Position, Velocity };

// Spawn entities using Commands (deferred component ops)
fn spawnSystem(commands: anytype) !void {
    const e1 = commands.createEntity();
    try commands.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try commands.addComponent(e1, Velocity, .{ .x = 1.0, .y = 2.0 });

    const e2 = commands.createEntity();
    try commands.addComponent(e2, Position, .{ .x = 5.0, .y = 5.0 });
    try commands.addComponent(e2, Velocity, .{ .x = -0.5, .y = 0.0 });
}

// Define system as plain function
fn movementSystem(group: sparze.Group(MovementGroup)) void {
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

    // Spawn initial entities via command buffer
    world.beginFrame();
    try world.runSystem(spawnSystem);
    try world.endFrame();

    // Run the system for a few frames.
    for (0..3) |_| {
        try world.runSystem(movementSystem);
    }

    // Print the final positions (first two entities in the movement group)
    const positions = world.getGroupComponents(MovementGroup, Position).?;
    std.debug.print("Entity 1 final position: ({d}, {d})\n", .{ positions[0].x, positions[0].y });
    std.debug.print("Entity 2 final position: ({d}, {d})\n", .{ positions[1].x, positions[1].y });
}
