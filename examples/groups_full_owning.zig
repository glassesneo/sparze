// groups_full_owning.zig - Fast Multi-Component Iteration with Groups
//
// This example demonstrates full-owning Groups for maximum performance:
// - Creating groups with world.createGroup()
// - Group iteration with getEntities(), getArrayOf(), getMutArrayOf()
// - Why groups are faster than Query (cache locality)
// - validateGroups() for compile-time overlap checking
// - When to use Groups vs Query
//
// Run with: zig build run-groups_full_owning

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Component Definitions
// =============================================================================
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32, max_hp: i32 };
const Armor = struct { value: i32 };

const World = sparze.World(
    struct { Position, Velocity, Health, Armor },
    struct {},
    struct {},
);

// =============================================================================
// Group Type Definitions
// =============================================================================
// Define group types as named constants for readability and reuse

const MovementGroup = struct { Position, Velocity };
const CombatGroup = struct { Health, Armor };

// =============================================================================
// Systems Using Groups
// =============================================================================

/// Movement system using Group for cache-friendly iteration
fn movementSystem(group: sparze.Group(MovementGroup)) !void {
    // Get direct array access to components - no indirection!
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    std.debug.print("  [movementSystem] Processing {} entities in group\n", .{positions.len});

    // Parallel array iteration - extremely cache-friendly
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.dx;
        pos.y += vel.dy;
    }
}

/// Combat system for health/armor management
fn combatSystem(group: sparze.Group(CombatGroup)) !void {
    const entities = group.getEntities();
    const healths = group.getMutArrayOf(Health);
    const armors = group.getMutArrayOf(Armor);

    std.debug.print("  [combatSystem] Processing {} entities\n", .{entities.len});

    // Apply damage to all entities in combat group
    const damage: i32 = 15;

    for (entities, healths, armors) |entity, *health, *armor| {
        const absorbed = @min(armor.value, damage);
        armor.value -= absorbed;
        const remaining = damage - absorbed;
        health.hp -= remaining;

        std.debug.print("    Entity {any}: armor={}, hp={}\n", .{ entity, armor.value, health.hp });
    }
}

/// Using Group with entity access for conditional logic
fn healingSystem(group: sparze.Group(CombatGroup)) !void {
    const entities = group.getEntities();
    const healths = group.getMutArrayOf(Health);

    std.debug.print("  [healingSystem] Healing low-health entities\n", .{});

    for (entities, healths) |entity, *health| {
        // Only heal if below 50% health
        if (health.hp < @divFloor(health.max_hp, 2)) {
            const heal_amount = @min(20, health.max_hp - health.hp);
            health.hp += heal_amount;
            std.debug.print("    Entity {any} healed for {} (hp={})\n", .{ entity, heal_amount, health.hp });
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Sparze ECS: Full-Owning Groups ===\n\n", .{});

    // ==========================================================================
    // Compile-Time Group Validation
    // ==========================================================================
    // RECOMMENDED: Validate all groups at compile time before creating them.
    // This catches component overlap errors at compile time!

    std.debug.print("--- Compile-time validation ---\n", .{});
    World.validateGroups(.{
        MovementGroup, // { Position, Velocity }
        CombatGroup, // { Health, Armor }
    });
    std.debug.print("  Groups validated: no component overlaps\n\n", .{});

    // If you tried to validate overlapping groups, you'd get a compile error:
    // World.validateGroups(.{
    //     struct { Position, Velocity },
    //     struct { Position, Health },  // ERROR: Position already owned!
    // });

    var world = World.init(allocator);
    defer world.deinit();

    // ==========================================================================
    // Create Groups (Runtime)
    // ==========================================================================
    std.debug.print("--- Creating groups ---\n", .{});

    try world.createGroup(MovementGroup);
    std.debug.print("  Created MovementGroup: {{ Position, Velocity }}\n", .{});

    try world.createGroup(CombatGroup);
    std.debug.print("  Created CombatGroup: {{ Health, Armor }}\n", .{});

    // Creating the same group twice is a no-op (idempotent)
    try world.createGroup(MovementGroup);
    std.debug.print("  Duplicate createGroup is safe (no-op)\n\n", .{});

    // ==========================================================================
    // Create Entities
    // ==========================================================================
    std.debug.print("--- Creating entities ---\n", .{});

    // Entity with all components (in both groups)
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .dx = 2.0, .dy = 1.0 });
    try world.addComponent(player, Health, .{ .hp = 100, .max_hp = 100 });
    try world.addComponent(player, Armor, .{ .value = 50 });
    std.debug.print("  Player: all components (in both groups)\n", .{});

    // Entity with only movement components
    const projectile = world.createEntity();
    try world.addComponent(projectile, Position, .{ .x = 10.0, .y = 5.0 });
    try world.addComponent(projectile, Velocity, .{ .dx = 10.0, .dy = 0.0 });
    std.debug.print("  Projectile: Position, Velocity (MovementGroup only)\n", .{});

    // Entity with only combat components
    const turret = world.createEntity();
    try world.addComponent(turret, Health, .{ .hp = 50, .max_hp = 50 });
    try world.addComponent(turret, Armor, .{ .value = 100 });
    std.debug.print("  Turret: Health, Armor (CombatGroup only)\n", .{});

    // Entity with Position only (no group)
    const marker = world.createEntity();
    try world.addComponent(marker, Position, .{ .x = 100.0, .y = 100.0 });
    std.debug.print("  Marker: Position only (entity {any}, no group)\n\n", .{marker});

    // ==========================================================================
    // Query Group Membership
    // ==========================================================================
    std.debug.print("--- Group membership ---\n", .{});

    const movement_entities = world.getGroupEntities(MovementGroup).?;
    std.debug.print("  MovementGroup entities: {}\n", .{movement_entities.len});

    const combat_entities = world.getGroupEntities(CombatGroup).?;
    std.debug.print("  CombatGroup entities: {}\n\n", .{combat_entities.len});

    // ==========================================================================
    // Run Systems
    // ==========================================================================
    std.debug.print("--- Running systems (3 frames) ---\n", .{});

    for (0..3) |frame| {
        std.debug.print("\nFrame {}:\n", .{frame});
        try world.runSystem(movementSystem);
        try world.runSystem(combatSystem);
        try world.runSystem(healingSystem);
    }

    // ==========================================================================
    // Dynamic Group Membership
    // ==========================================================================
    std.debug.print("\n--- Dynamic membership ---\n", .{});

    // Adding velocity to turret adds it to MovementGroup
    std.debug.print("  Adding Velocity to turret...\n", .{});
    try world.addComponent(turret, Velocity, .{ .dx = 0.5, .dy = 0.0 });

    const new_movement = world.getGroupEntities(MovementGroup).?;
    std.debug.print("  MovementGroup now has {} entities\n", .{new_movement.len});

    // Removing velocity removes from group
    std.debug.print("  Removing Velocity from turret...\n", .{});
    world.removeComponent(turret, Velocity);

    const after_remove = world.getGroupEntities(MovementGroup).?;
    std.debug.print("  MovementGroup now has {} entities\n", .{after_remove.len});

    // ==========================================================================
    // Performance Comparison
    // ==========================================================================
    std.debug.print("\n=== Performance: Group vs Query ===\n", .{});
    std.debug.print("Group advantages:\n", .{});
    std.debug.print("  - Direct array access (no indirection)\n", .{});
    std.debug.print("  - Components stored contiguously for entities in group\n", .{});
    std.debug.print("  - No filter() call needed - all entities valid\n", .{});
    std.debug.print("  - Cache-friendly: sequential memory access\n", .{});
    std.debug.print("\nQuery advantages:\n", .{});
    std.debug.print("  - No upfront setup required\n", .{});
    std.debug.print("  - Supports Optional and Exclude modifiers\n", .{});
    std.debug.print("  - More flexible for ad-hoc queries\n", .{});
    std.debug.print("\nRule of thumb:\n", .{});
    std.debug.print("  - Use Groups for hot-path systems (every frame)\n", .{});
    std.debug.print("  - Use Query for occasional/debug queries\n", .{});

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("\n=== Key Takeaways ===\n", .{});
    std.debug.print("1. Create groups with world.createGroup(struct {{ A, B }})\n", .{});
    std.debug.print("2. Use validateGroups() for compile-time overlap checking\n", .{});
    std.debug.print("3. getArrayOf()/getMutArrayOf() give direct array access\n", .{});
    std.debug.print("4. Group membership updates automatically on add/remove\n", .{});
    std.debug.print("5. Groups provide maximum iteration performance\n", .{});
    std.debug.print("6. Each component can only be OWNED by one group\n", .{});
}
