// queries_filters.zig - Multi-Component Queries with Optional and Exclude
//
// This example demonstrates Query for flexible entity filtering:
// - Query(struct { A, B }) for multi-component iteration
// - Optional components with ?T syntax
// - Exclude components with Exclude(T) to filter out entities
// - Comparison with SingleQuery for single components
// - Using filter() to validate entities during iteration
//
// Run with: zig build run-queries_filters

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Component Definitions
// =============================================================================
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32, max_hp: i32 };
const Shield = struct { value: i32 };
const Invulnerable = struct {}; // Tag component - entities with this can't be damaged

const World = sparze.World(
    struct { Position, Velocity, Health, Shield, Invulnerable },
    struct {},
    struct {},
);

// =============================================================================
// Systems Demonstrating Query Patterns
// =============================================================================

/// Basic Query: entities with BOTH Position AND Velocity
fn movementSystem(query: sparze.Query(struct { Position, Velocity })) !void {
    std.debug.print("  [movementSystem] Iterating entities with Position AND Velocity\n", .{});

    for (query.entities) |entity| {
        // IMPORTANT: Always call filter() to ensure entity has all required components
        // The entity list comes from the smallest component set, but we need to verify
        // the entity has ALL components in the query.
        if (!query.filter(entity)) continue;

        // Safe to access components after filter passes
        const pos = query.getComponentMut(entity, Position);
        const vel = query.getComponent(entity, Velocity);

        pos.x += vel.dx;
        pos.y += vel.dy;

        std.debug.print("    Entity {any} moved to ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
    }
}

/// Query with Optional: Health is required, Shield is optional
fn damageSystem(query: sparze.Query(struct { Health, ?Shield })) !void {
    std.debug.print("  [damageSystem] Processing entities with Health (Shield optional)\n", .{});

    const damage: i32 = 25;

    for (query.entities) |entity| {
        if (!query.filter(entity)) continue;

        const health = query.getComponentMut(entity, Health);

        // Optional component returns null if not present
        if (query.getOptionalMut(entity, Shield)) |shield| {
            // Has shield - absorb damage first
            const absorbed = @min(shield.value, damage);
            shield.value -= absorbed;
            const remaining = damage - absorbed;
            health.hp -= remaining;
            std.debug.print("    Entity {any}: shield absorbed {}, took {} (HP: {})\n", .{ entity, absorbed, remaining, health.hp });
        } else {
            // No shield - take full damage
            health.hp -= damage;
            std.debug.print("    Entity {any}: no shield, took {} (HP: {})\n", .{ entity, damage, health.hp });
        }
    }
}

/// Query with Exclude: Health required, Invulnerable entities filtered OUT
fn vulnerableDamageSystem(query: sparze.Query(struct { Health, sparze.Exclude(Invulnerable) })) !void {
    std.debug.print("  [vulnerableDamageSystem] Damaging entities WITHOUT Invulnerable tag\n", .{});

    const damage: i32 = 10;

    for (query.entities) |entity| {
        // filter() automatically excludes entities with Invulnerable
        if (!query.filter(entity)) continue;

        const health = query.getComponentMut(entity, Health);
        health.hp -= damage;
        std.debug.print("    Entity {any} took {} damage (HP: {})\n", .{ entity, damage, health.hp });
    }
}

/// Combined Optional + Exclude: Position required, Velocity optional, Invulnerable excluded
fn renderVulnerableSystem(query: sparze.Query(struct { Position, ?Velocity, sparze.Exclude(Invulnerable) })) !void {
    std.debug.print("  [renderVulnerableSystem] Rendering vulnerable entities (excluding Invulnerable)\n", .{});

    for (query.entities) |entity| {
        // filter() checks both: entity has Position, and entity does NOT have Invulnerable
        if (!query.filter(entity)) continue;

        const pos = query.getComponent(entity, Position);

        const vel_str = if (query.getOptional(entity, Velocity)) |vel|
            std.fmt.allocPrint(std.heap.page_allocator, "moving ({d:.1}, {d:.1})", .{ vel.dx, vel.dy }) catch "?"
        else
            "static";

        std.debug.print("    Entity {any} at ({d:.1}, {d:.1}) - {s}\n", .{
            entity,
            pos.x,
            pos.y,
            vel_str,
        });
    }
}

/// Demonstration of counting entities that pass the filter
fn entityCountDemo(query: sparze.Query(struct { Position, Health })) !void {
    std.debug.print("  [entityCountDemo] Counting entities with Position AND Health\n", .{});

    var count: u32 = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            count += 1;
            const pos = query.getComponent(entity, Position);
            std.debug.print("    Found entity {any} at ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
        }
    }

    std.debug.print("    Total: {} entities with both components\n", .{count});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("=== Sparze ECS: Query Filters ===\n\n", .{});

    // ==========================================================================
    // Create Diverse Entities
    // ==========================================================================
    std.debug.print("--- Creating entities ---\n", .{});

    // Entity 1: Moving character with health and shield
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .dx = 1.0, .dy = 0.5 });
    try world.addComponent(player, Health, .{ .hp = 100, .max_hp = 100 });
    try world.addComponent(player, Shield, .{ .value = 50 });
    std.debug.print("  Player: Position, Velocity, Health, Shield\n", .{});

    // Entity 2: Static turret with health only
    const turret = world.createEntity();
    try world.addComponent(turret, Position, .{ .x = 50.0, .y = 50.0 });
    try world.addComponent(turret, Health, .{ .hp = 75, .max_hp = 75 });
    std.debug.print("  Turret: Position, Health (no Velocity)\n", .{});

    // Entity 3: Moving enemy with health
    const enemy = world.createEntity();
    try world.addComponent(enemy, Position, .{ .x = 100.0, .y = 0.0 });
    try world.addComponent(enemy, Velocity, .{ .dx = -2.0, .dy = 0.0 });
    try world.addComponent(enemy, Health, .{ .hp = 50, .max_hp = 50 });
    std.debug.print("  Enemy: Position, Velocity, Health\n", .{});

    // Entity 4: Invulnerable boss
    const boss = world.createEntity();
    try world.addComponent(boss, Position, .{ .x = 200.0, .y = 100.0 });
    try world.addComponent(boss, Health, .{ .hp = 500, .max_hp = 500 });
    try world.addComponent(boss, Invulnerable, .{});
    std.debug.print("  Boss: Position, Health, Invulnerable (immune to damage)\n", .{});

    // Entity 5: Decoration (position only)
    const decoration = world.createEntity();
    try world.addComponent(decoration, Position, .{ .x = 75.0, .y = 25.0 });
    std.debug.print("  Decoration: Position only (entity {any})\n", .{decoration});

    std.debug.print("\n", .{});

    // ==========================================================================
    // Run Systems
    // ==========================================================================
    std.debug.print("--- Running movement (Position AND Velocity required) ---\n", .{});
    try world.runSystem(movementSystem);

    std.debug.print("\n--- Running damage with optional Shield ---\n", .{});
    try world.runSystem(damageSystem);

    std.debug.print("\n--- Running damage excluding Invulnerable ---\n", .{});
    try world.runSystem(vulnerableDamageSystem);

    std.debug.print("\n--- Rendering with Optional + Exclude combined ---\n", .{});
    try world.runSystem(renderVulnerableSystem);

    std.debug.print("\n--- Entity count demonstration ---\n", .{});
    try world.runSystem(entityCountDemo);

    // ==========================================================================
    // SingleQuery vs Query Comparison
    // ==========================================================================
    std.debug.print("\n--- SingleQuery vs Query ---\n", .{});

    // SingleQuery: Fast, single component, no filtering needed
    const single = sparze.SingleQuery(Position).init(world.getSparseSetPtr(Position));
    std.debug.print("  SingleQuery(Position): {} entities (all with Position)\n", .{single.entities.len});

    // Query: Multi-component, requires filter() call
    const multi = sparze.Query(struct { Position, Velocity }).init(&world);
    var multi_count: u32 = 0;
    for (multi.entities) |e| {
        if (multi.filter(e)) multi_count += 1;
    }
    std.debug.print("  Query(Position, Velocity): {} entities (filtered)\n", .{multi_count});

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("\n=== Key Takeaways ===\n", .{});
    std.debug.print("1. Query(struct {{ A, B }}) requires entities to have ALL listed components\n", .{});
    std.debug.print("2. ?T makes a component optional - use getOptional() to access\n", .{});
    std.debug.print("3. Exclude(T) filters OUT entities that have the component\n", .{});
    std.debug.print("4. ALWAYS call filter(entity) before accessing components\n", .{});
    std.debug.print("5. Use SingleQuery for hot paths with single components\n", .{});
    std.debug.print("6. ?T and Exclude(T) can be combined in the same Query\n", .{});
    std.debug.print("7. Query is flexible but slower than Groups (see groups_full_owning.zig)\n", .{});
}
