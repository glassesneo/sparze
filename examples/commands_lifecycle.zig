// commands_lifecycle.zig - Safe Mutations with Commands and Frame Lifecycle
//
// This example demonstrates deferred entity/component operations:
// - Using Commands for safe mutations during system execution
// - The beginFrame/endFrame lifecycle
// - Why deferred operations matter (iterator safety)
// - createEntityWith for batch entity creation
//
// Run with: zig build run-commands_lifecycle

const std = @import("std");
const sparze = @import("sparze");

// Components
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Expired = struct {}; // Marker for entities to be destroyed

const World = sparze.World(
    struct { Position, Velocity, Health, Expired },
    struct {},
    struct {},
);

// =============================================================================
// System Functions
// =============================================================================
// Systems receive parameters via dependency injection. Use `anytype` for Commands.

/// Spawns new entities using Commands (deferred component addition)
fn spawnSystem(commands: anytype) !void {
    std.debug.print("  [spawnSystem] Creating entities via Commands\n", .{});

    // createEntity() is immediate - we get a valid Entity handle right away
    const e1 = commands.createEntity();
    // addComponent() is deferred - recorded now, applied at endFrame()
    try commands.addComponent(e1, Position, .{ .x = 0.0, .y = 0.0 });
    try commands.addComponent(e1, Velocity, .{ .dx = 1.0, .dy = 0.5 });
    try commands.addComponent(e1, Health, .{ .hp = 100 });

    // createEntityWith() combines both - immediate entity, deferred components
    _ = try commands.createEntityWith(.{
        Position{ .x = 10.0, .y = 10.0 },
        Velocity{ .dx = -0.5, .dy = 1.0 },
        Health{ .hp = 50 },
    });

    std.debug.print("  [spawnSystem] Recorded 2 entities (applied at endFrame)\n", .{});
}

/// Updates positions based on velocity
fn movementSystem(query: sparze.SingleQuery(Position), vel_storage: sparze.SingleQuery(Velocity)) !void {
    std.debug.print("  [movementSystem] Processing {} entities\n", .{query.entities.len});

    // Get mutable position storage
    for (query.entities, query.components) |entity, *pos| {
        // Check if entity also has velocity
        if (vel_storage.components.len > 0) {
            // Find velocity for this entity (simplified - real code would use Query)
            for (vel_storage.entities, vel_storage.components) |vel_entity, vel| {
                if (entity == vel_entity) {
                    pos.x += vel.dx;
                    pos.y += vel.dy;
                    break;
                }
            }
        }
    }
}

/// Marks low-health entities for destruction
fn healthCheckSystem(
    health_query: sparze.SingleQuery(Health),
    commands: anytype,
) !void {
    var marked: u32 = 0;
    for (health_query.entities, health_query.components) |entity, health| {
        if (health.hp <= 0) {
            // Don't destroy directly during iteration - use Commands!
            try commands.addComponent(entity, Expired, .{});
            marked += 1;
        }
    }
    if (marked > 0) {
        std.debug.print("  [healthCheckSystem] Marked {} entities as expired\n", .{marked});
    }
}

/// Destroys all expired entities
fn cleanupSystem(
    expired_query: sparze.SingleTag(Expired),
    commands: anytype,
) !void {
    for (expired_query.entities) |entity| {
        // Deferred destruction - safe during iteration
        try commands.destroyEntity(entity);
    }
    if (expired_query.entities.len > 0) {
        std.debug.print("  [cleanupSystem] Queued {} entities for destruction\n", .{expired_query.entities.len});
    }
}

/// Applies damage to all entities (for demonstration)
fn damageSystem(health_query: sparze.SingleQuery(Health)) !void {
    for (health_query.components) |*health| {
        health.hp -= 30;
    }
    std.debug.print("  [damageSystem] Applied 30 damage to {} entities\n", .{health_query.entities.len});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("=== Sparze ECS: Commands and Frame Lifecycle ===\n\n", .{});

    // ==========================================================================
    // Frame 0: Initial spawn
    // ==========================================================================
    std.debug.print("--- Frame 0: Spawning entities ---\n", .{});

    // beginFrame() swaps event buffers and clears the command buffer
    world.beginFrame();

    // Run the spawn system - commands are recorded but NOT executed yet
    try world.runSystem(spawnSystem);

    // At this point, entities exist but have no components!
    const before_flush = sparze.SingleQuery(Position).init(world.getSparseSetPtr(Position));
    std.debug.print("  Entities with Position BEFORE endFrame: {}\n", .{before_flush.entities.len});

    // endFrame() executes all recorded commands
    try world.endFrame();

    // Now the components are attached
    const after_flush = sparze.SingleQuery(Position).init(world.getSparseSetPtr(Position));
    std.debug.print("  Entities with Position AFTER endFrame: {}\n\n", .{after_flush.entities.len});

    // ==========================================================================
    // Frame 1: Movement
    // ==========================================================================
    std.debug.print("--- Frame 1: Movement ---\n", .{});
    world.beginFrame();

    try world.runSystem(movementSystem);

    // Print positions
    const pos_query = sparze.SingleQuery(Position).init(world.getSparseSetPtr(Position));
    for (pos_query.entities, pos_query.components) |entity, pos| {
        std.debug.print("  Entity {any} at ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
    }

    try world.endFrame();
    std.debug.print("\n", .{});

    // ==========================================================================
    // Frames 2-4: Damage and cleanup cycle
    // ==========================================================================
    var frame: u32 = 2;
    while (frame <= 5) : (frame += 1) {
        std.debug.print("--- Frame {} ---\n", .{frame});
        world.beginFrame();

        // Apply damage
        try world.runSystem(damageSystem);

        // Check for dead entities and mark them
        try world.runSystem(healthCheckSystem);

        // Clean up marked entities
        try world.runSystem(cleanupSystem);

        try world.endFrame();

        // Report surviving entities
        const survivors = sparze.SingleQuery(Health).init(world.getSparseSetPtr(Health));
        std.debug.print("  Surviving entities: {}\n\n", .{survivors.entities.len});

        if (survivors.entities.len == 0) {
            std.debug.print("All entities destroyed!\n", .{});
            break;
        }
    }

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("=== Key Takeaways ===\n", .{});
    std.debug.print("1. commands.createEntity() is IMMEDIATE - returns valid handle\n", .{});
    std.debug.print("2. commands.addComponent() is DEFERRED - applied at endFrame()\n", .{});
    std.debug.print("3. commands.destroyEntity() is DEFERRED - safe during iteration\n", .{});
    std.debug.print("4. Always call beginFrame() before systems, endFrame() after\n", .{});
    std.debug.print("5. Use Commands in systems to avoid iterator invalidation\n", .{});
}
