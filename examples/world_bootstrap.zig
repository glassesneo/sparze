// world_bootstrap.zig - Minimal World Setup and Single-Component Iteration
//
// This example demonstrates the absolute basics of Sparze ECS:
// - Defining a World type with components
// - Creating and destroying entities
// - Adding components to entities
// - Iterating over entities with SingleQuery
//
// Run with: zig build run-world_bootstrap

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Step 1: Define Components
// =============================================================================
// Components are plain Zig structs. They hold data - no behavior.
// Keep components small and focused on a single aspect.

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
};

// =============================================================================
// Step 2: Define the World Type
// =============================================================================
// World is parameterized by four tuples: (Components, Resources, Events, Groups)
// - Components: Data attached to entities
// - Resources: Global singleton data (covered in example 03)
// - Events: Frame-to-frame messages (covered in example 08)
// - Groups: Compile-time group definitions (none for this minimal example)

const World = sparze.World(
    struct { Position, Velocity }, // Components this world can store
    struct {}, // No resources for now
    struct {}, // No events for now
    .{}, // No groups for now
);

pub fn main() !void {
    // ==========================================================================
    // Step 3: Initialize the World
    // ==========================================================================
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("=== Sparze ECS: World Bootstrap ===\n\n", .{});

    // ==========================================================================
    // Step 4: Create Entities and Add Components (Immediate Mode)
    // ==========================================================================
    // In immediate mode, operations happen right away. This is useful for
    // initial setup. For runtime modifications, prefer Commands (example 02).

    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .dx = 1.0, .dy = 0.5 });
    std.debug.print("Created player entity: {any}\n", .{player});

    // Create some NPCs - only with Position (no velocity = static)
    const npc1 = world.createEntity();
    try world.addComponent(npc1, Position, .{ .x = 10.0, .y = 20.0 });

    const npc2 = world.createEntity();
    try world.addComponent(npc2, Position, .{ .x = 30.0, .y = 40.0 });

    std.debug.print("Created 2 NPC entities\n\n", .{});

    // ==========================================================================
    // Step 5: Query Entities with SingleQuery
    // ==========================================================================
    // SingleQuery(T) iterates ALL entities that have component T.
    // It provides parallel arrays: entities[] and components[]

    std.debug.print("--- All entities with Position ---\n", .{});
    const pos_query = sparze.SingleQuery(Position).init(world.getSparseSetPtr(Position));

    for (pos_query.entities, pos_query.components) |entity, pos| {
        std.debug.print("  Entity {any} at ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
    }

    std.debug.print("\n--- All entities with Velocity ---\n", .{});
    const vel_query = sparze.SingleQuery(Velocity).init(world.getSparseSetPtr(Velocity));

    for (vel_query.entities, vel_query.components) |entity, vel| {
        std.debug.print("  Entity {any} moving ({d:.1}, {d:.1})\n", .{ entity, vel.dx, vel.dy });
    }

    // ==========================================================================
    // Step 6: Modify Components
    // ==========================================================================
    // Get mutable access to update component values

    std.debug.print("\n--- Updating player position ---\n", .{});
    const sparse_set = world.getSparseSetPtrMut(Position);
    if (sparse_set.getPtrMut(player)) |pos| {
        std.debug.print("  Before: ({d:.1}, {d:.1})\n", .{ pos.x, pos.y });
        pos.x += 5.0;
        pos.y += 2.5;
        std.debug.print("  After:  ({d:.1}, {d:.1})\n", .{ pos.x, pos.y });
    }

    // ==========================================================================
    // Step 7: Check Entity State
    // ==========================================================================
    std.debug.print("\n--- Entity state checks ---\n", .{});
    std.debug.print("  Player is alive: {}\n", .{world.isAlive(player)});
    std.debug.print("  Player has Position: {}\n", .{world.hasComponent(player, Position)});
    std.debug.print("  Player has Velocity: {}\n", .{world.hasComponent(player, Velocity)});
    std.debug.print("  NPC1 has Velocity: {}\n", .{world.hasComponent(npc1, Velocity)});

    // ==========================================================================
    // Step 8: Remove Components and Destroy Entities
    // ==========================================================================
    std.debug.print("\n--- Removing velocity from player ---\n", .{});
    world.removeComponent(player, Velocity);
    std.debug.print("  Player has Velocity: {}\n", .{world.hasComponent(player, Velocity)});

    std.debug.print("\n--- Destroying NPC1 ---\n", .{});
    world.destroyEntity(npc1);
    std.debug.print("  NPC1 is alive: {}\n", .{world.isAlive(npc1)});

    // After destruction, position query shows fewer entities
    std.debug.print("\n--- Remaining entities with Position ---\n", .{});
    const remaining = sparze.SingleQuery(Position).init(world.getSparseSetPtr(Position));
    std.debug.print("  Count: {}\n", .{remaining.entities.len});

    std.debug.print("\n=== Example Complete ===\n", .{});
}
