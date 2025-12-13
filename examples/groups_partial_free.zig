// groups_partial_free.zig - Partial-Owning Groups with Free(T)
//
// This example demonstrates partial-owning groups using Free(T):
// - Owned vs Free components in a group
// - When to use Free(T) for component sharing between groups
// - Performance trade-offs (direct array vs sparse lookup)
// - Hot/cold data separation patterns
//
// Run with: zig build run-groups_partial_free

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Component Definitions
// =============================================================================

// HOT DATA - Accessed every frame, benefits from cache locality
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

// COLD DATA - Accessed occasionally, fine with sparse lookup
const Health = struct { hp: i32, max_hp: i32 };
const Name = struct { value: [32]u8, len: u8 };

// Rendering data - owned by render group
const Sprite = struct { texture_id: u32, layer: i32 };
const Color = struct { r: u8, g: u8, b: u8, a: u8 };

const World = sparze.World(
    struct { Position, Velocity, Health, Name, Sprite, Color },
    struct {},
    struct {},
);

// =============================================================================
// Group Type Definitions
// =============================================================================

// Movement group: Owns Position & Velocity (hot path), Health is free (cold data)
// - Position/Velocity accessed via direct arrays (cache-friendly)
// - Health accessed via sparse lookup (but still REQUIRED)
const MovementGroup = struct { Position, Velocity, sparze.Free(Health) };

// Render group: Owns Sprite & Color, Position is free
// - Position is accessed via sparse lookup
// - Sprite/Color use direct array access
const RenderGroup = struct { sparze.Free(Position), Sprite, Color };

// Health management group: Owns Health, Position is free
// - This allows Health to be in different groups with different ownership
const HealthGroup = struct { Health, sparze.Free(Position) };

// =============================================================================
// Systems Using Partial-Owning Groups
// =============================================================================

/// Movement system - owned components use direct array access
fn movementSystem(group: sparze.Group(MovementGroup)) !void {
    // Owned components: direct parallel array access (maximum performance)
    const positions = group.getMutArrayOf(Position);
    const velocities = group.getArrayOf(Velocity);

    std.debug.print("  [movementSystem] Processing {} entities\n", .{positions.len});

    for (group.getEntities(), positions, velocities) |entity, *pos, vel| {
        pos.x += vel.dx;
        pos.y += vel.dy;

        // Free component: accessed via entity lookup (sparse set indirection)
        // This is slightly slower but allows Health to be owned by another group
        const health = group.getComponent(entity, Health);

        // Skip dead entities (health check uses free component)
        if (health.hp <= 0) {
            std.debug.print("    Entity {any} is dead, skipping\n", .{entity});
            continue;
        }

        std.debug.print("    Entity {any} at ({d:.1}, {d:.1}) HP={}\n", .{
            entity,
            pos.x,
            pos.y,
            health.hp,
        });
    }
}

/// Render system - different owned components
fn renderSystem(group: sparze.Group(RenderGroup)) !void {
    // Owned: Sprite and Color (direct array access)
    const sprites = group.getArrayOf(Sprite);
    const colors = group.getArrayOf(Color);

    std.debug.print("  [renderSystem] Rendering {} entities\n", .{sprites.len});

    for (group.getEntities(), sprites, colors) |entity, sprite, color| {
        // Free component: Position accessed via lookup
        const pos = group.getComponent(entity, Position);

        std.debug.print("    Entity {any}: sprite={} at ({d:.1}, {d:.1}) color=rgba({},{},{},{})\n", .{
            entity,
            sprite.texture_id,
            pos.x,
            pos.y,
            color.r,
            color.g,
            color.b,
            color.a,
        });
    }
}

/// Health management system
fn healthSystem(group: sparze.Group(HealthGroup)) !void {
    // Owned: Health (direct array access)
    const healths = group.getMutArrayOf(Health);

    std.debug.print("  [healthSystem] Processing {} entities\n", .{healths.len});

    for (group.getEntities(), healths) |entity, *health| {
        // Free component: Position accessed via lookup
        const pos = group.getComponent(entity, Position);

        // Heal entities that are in safe zone (x < 10)
        if (pos.x < 10.0 and health.hp < health.max_hp) {
            health.hp = @min(health.hp + 5, health.max_hp);
            std.debug.print("    Entity {any}: healed in safe zone (HP={})\n", .{ entity, health.hp });
        } else {
            std.debug.print("    Entity {any}: at ({d:.1}, {d:.1}) HP={}/{}\n", .{
                entity,
                pos.x,
                pos.y,
                health.hp,
                health.max_hp,
            });
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Sparze ECS: Partial-Owning Groups with Free(T) ===\n\n", .{});

    var world = World.init(allocator);
    defer world.deinit();

    // ==========================================================================
    // Create Groups - Order Matters!
    // ==========================================================================
    std.debug.print("--- Creating partial-owning groups ---\n", .{});

    // Group 1: Owns Position, Velocity; Health is Free
    try world.createGroup(MovementGroup);
    std.debug.print("  MovementGroup: owns {{ Position, Velocity }}, free {{ Health }}\n", .{});

    // Group 2: Owns Sprite, Color; Position is Free
    // This works because Position is marked as Free (not owned)
    try world.createGroup(RenderGroup);
    std.debug.print("  RenderGroup: owns {{ Sprite, Color }}, free {{ Position }}\n", .{});

    // Group 3: Owns Health; Position is Free
    // Health is free in MovementGroup, so HealthGroup can own it
    try world.createGroup(HealthGroup);
    std.debug.print("  HealthGroup: owns {{ Health }}, free {{ Position }}\n\n", .{});

    // ==========================================================================
    // Create Entities
    // ==========================================================================
    std.debug.print("--- Creating entities ---\n", .{});

    // Entity 1: In MovementGroup (has Position, Velocity, Health)
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .dx = 1.0, .dy = 0.5 });
    try world.addComponent(player, Health, .{ .hp = 100, .max_hp = 100 });
    std.debug.print("  Player: Position, Velocity, Health (in MovementGroup)\n", .{});

    // Entity 2: In both MovementGroup AND RenderGroup
    const enemy = world.createEntity();
    try world.addComponent(enemy, Position, .{ .x = 50.0, .y = 50.0 });
    try world.addComponent(enemy, Velocity, .{ .dx = -0.5, .dy = 0.0 });
    try world.addComponent(enemy, Health, .{ .hp = 30, .max_hp = 30 });
    try world.addComponent(enemy, Sprite, .{ .texture_id = 1, .layer = 0 });
    try world.addComponent(enemy, Color, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    std.debug.print("  Enemy: All components (in MovementGroup + RenderGroup)\n", .{});

    // Entity 3: In RenderGroup only (no velocity = static decoration)
    const decoration = world.createEntity();
    try world.addComponent(decoration, Position, .{ .x = 100.0, .y = 0.0 });
    try world.addComponent(decoration, Sprite, .{ .texture_id = 2, .layer = -1 });
    try world.addComponent(decoration, Color, .{ .r = 0, .g = 255, .b = 0, .a = 128 });
    std.debug.print("  Decoration: Position, Sprite, Color (in RenderGroup only)\n", .{});

    // Entity 4: In HealthGroup (Position + Health)
    const marker = world.createEntity();
    try world.addComponent(marker, Position, .{ .x = 5.0, .y = 5.0 });
    try world.addComponent(marker, Health, .{ .hp = 50, .max_hp = 100 });
    std.debug.print("  Marker: Position, Health (in HealthGroup)\n\n", .{});

    // ==========================================================================
    // Check Group Membership
    // ==========================================================================
    std.debug.print("--- Group membership ---\n", .{});

    if (world.getGroupEntities(MovementGroup)) |entities| {
        std.debug.print("  MovementGroup: {} entities\n", .{entities.len});
    }

    if (world.getGroupEntities(RenderGroup)) |entities| {
        std.debug.print("  RenderGroup: {} entities\n", .{entities.len});
    }

    if (world.getGroupEntities(HealthGroup)) |entities| {
        std.debug.print("  HealthGroup: {} entities\n", .{entities.len});
    }
    std.debug.print("\n", .{});

    // ==========================================================================
    // Run Systems
    // ==========================================================================
    std.debug.print("--- Running systems ---\n", .{});

    try world.runSystem(movementSystem);
    std.debug.print("\n", .{});

    try world.runSystem(renderSystem);
    std.debug.print("\n", .{});

    try world.runSystem(healthSystem);
    std.debug.print("\n", .{});

    // ==========================================================================
    // Performance Comparison
    // ==========================================================================
    std.debug.print("=== Owned vs Free Component Access ===\n", .{});
    std.debug.print("\nOwned components (getArrayOf/getMutArrayOf):\n", .{});
    std.debug.print("  - Direct array access\n", .{});
    std.debug.print("  - Components stored contiguously for group entities\n", .{});
    std.debug.print("  - Best for hot data (Position, Velocity)\n", .{});
    std.debug.print("  - Can ONLY be owned by ONE group\n", .{});

    std.debug.print("\nFree components (getComponent/getComponentMut):\n", .{});
    std.debug.print("  - Sparse set lookup per entity\n", .{});
    std.debug.print("  - Some cache misses during iteration\n", .{});
    std.debug.print("  - Good for cold data (Health, Name, Config)\n", .{});
    std.debug.print("  - Can be used by MULTIPLE groups\n", .{});

    std.debug.print("\nUse Case: Hot/Cold Data Separation\n", .{});
    std.debug.print("  - MovementGroup {{ Position, Velocity, Free(Health) }}\n", .{});
    std.debug.print("  - Position/Velocity: every-frame access → owned\n", .{});
    std.debug.print("  - Health: occasional damage checks → free\n", .{});

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("\n=== Key Takeaways ===\n", .{});
    std.debug.print("1. Free(T) marks a component as required but NOT owned\n", .{});
    std.debug.print("2. Owned components use direct array access (fastest)\n", .{});
    std.debug.print("3. Free components use sparse lookup (still fast, just slower)\n", .{});
    std.debug.print("4. A component can be owned by ONE group, free in MANY groups\n", .{});
    std.debug.print("5. Use owned for hot data, free for cold/shared data\n", .{});
}
