// Practical example demonstrating multiple non‑overlapping groups and compile‑time validation.
// Run with `zig build run-examples` after adding this file to `examples` in build.zig.

const std = @import("std");
const sparze = @import("sparze");

// Component definitions
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { hp: i32 };
const Armor = struct { defense: i32 };

// Define World type
const World = sparze.World(struct { Position, Velocity, Health, Armor });

// Declare group type constants for better readability and maintainability
const MovementGroup = struct { Position, Velocity };
const CombatGroup = struct { Health, Armor };

// Define systems as plain functions
fn movementSystem(group: sparze.Group(MovementGroup)) !void {
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

fn combatSystem(group: sparze.Group(CombatGroup)) !void {
    const healths = group.getArrayOf(Health);
    const armors = group.getArrayOf(Armor);
    for (healths, armors) |health, armor| {
        std.debug.print("Combat entity - HP: {d}, Defense: {d}\n", .{ health.hp, armor.defense });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compile‑time validation of groups – will error if overlapping.
    comptime World.validateGroups(.{
        MovementGroup,
        CombatGroup,
    });

    var world = World.init(allocator);
    defer world.deinit();

    // Create the groups at runtime (they were validated at compile time).
    try world.createGroup(MovementGroup);
    try world.createGroup(CombatGroup);

    // Create a moving entity with Position & Velocity.
    const mover = world.createEntity();
    try world.addComponent(mover, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(mover, Velocity, .{ .x = 1.0, .y = 1.5 });

    // Create a combat entity with Health & Armor.
    const combatant = world.createEntity();
    try world.addComponent(combatant, Health, .{ .hp = 100 });
    try world.addComponent(combatant, Armor, .{ .defense = 20 });

    // Run each system a few frames.
    for (0..3) |_| {
        try world.runSystem(movementSystem);
        try world.runSystem(combatSystem);
    }

    // Show final position of the mover.
    const finalPos = world.getComponent(mover, Position).?;
    std.debug.print("Mover final position: ({d}, {d})\n", .{ finalPos.x, finalPos.y });
}
