// tags_and_tagquery.zig - Zero-Sized Tag Components
//
// This example demonstrates tag components (zero-sized markers):
// - Defining tags (empty structs)
// - addTag/removeTag for efficient tag manipulation
// - SingleTag for iterating entities with a single tag
// - TagQuery for multi-tag filtering with Optional/Exclude
// - When to prefer tags over regular components
//
// Run with: zig build run-tags_and_tagquery

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Component Definitions
// =============================================================================
const Position = struct { x: f32, y: f32 };
const Health = struct { hp: i32 };

// =============================================================================
// Tag Definitions
// =============================================================================
// Tags are zero-sized structs - they carry no data, only mark entities.
// Use tags for boolean-like properties: "is this entity a player?", "is it active?"

const Player = struct {}; // Marks the player entity
const Enemy = struct {}; // Marks enemy entities
const Boss = struct {}; // Additional marker for boss enemies
const Active = struct {}; // Entity is active/enabled
const Poisoned = struct {}; // Entity has poison status effect

const World = sparze.World(
    struct { Position, Health, Player, Enemy, Boss, Active, Poisoned },
    struct {},
    struct {},
    .{},
);

// =============================================================================
// Systems Using Tags
// =============================================================================

/// Process only player entities
fn playerInputSystem(players: sparze.SingleTag(Player), positions: sparze.SingleQuery(Position)) !void {
    std.debug.print("  [playerInputSystem] Processing player input\n", .{});

    for (players.entities) |entity| {
        // Check if entity has Position
        for (positions.entities, positions.components) |pos_entity, *pos| {
            if (entity == pos_entity) {
                // Simulate input: move right
                pos.x += 5.0;
                std.debug.print("    Player {any} moved to ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
                break;
            }
        }
    }
}

/// Process all enemies (basic + boss)
fn enemyAISystem(enemies: sparze.SingleTag(Enemy)) !void {
    std.debug.print("  [enemyAISystem] Processing {} enemies\n", .{enemies.entities.len});

    for (enemies.entities) |entity| {
        std.debug.print("    Enemy {any} thinking...\n", .{entity});
    }
}

/// TagQuery: Process entities that are Enemy AND Boss
fn bossSystem(query: sparze.TagQuery(struct { Enemy, Boss })) !void {
    std.debug.print("  [bossSystem] Processing boss enemies\n", .{});

    for (query.entities) |entity| {
        if (!query.filter(entity)) continue;
        std.debug.print("    Boss {any} doing special attack!\n", .{entity});
    }
}

/// TagQuery with Optional: All enemies, check if they're bosses
fn enemyRenderSystem(query: sparze.TagQuery(struct { Enemy, ?Boss })) !void {
    std.debug.print("  [enemyRenderSystem] Rendering enemies\n", .{});

    for (query.entities) |entity| {
        if (!query.filter(entity)) continue;

        const is_boss = query.hasTag(entity, Boss);
        const label = if (is_boss) "BOSS" else "enemy";
        std.debug.print("    Rendering {s} {any}\n", .{ label, entity });
    }
}

/// TagQuery with Exclude: Active enemies that are NOT poisoned
fn healthyEnemySystem(query: sparze.TagQuery(struct { Enemy, Active, sparze.Exclude(Poisoned) })) !void {
    std.debug.print("  [healthyEnemySystem] Processing healthy active enemies\n", .{});

    for (query.entities) |entity| {
        if (!query.filter(entity)) continue;
        std.debug.print("    Healthy enemy {any} attacks!\n", .{entity});
    }
}

/// Apply poison damage to poisoned entities
fn poisonSystem(
    poisoned: sparze.SingleTag(Poisoned),
    health_query: sparze.SingleQuery(Health),
) !void {
    std.debug.print("  [poisonSystem] Applying poison damage\n", .{});

    for (poisoned.entities) |entity| {
        for (health_query.entities, health_query.components) |h_entity, *health| {
            if (entity == h_entity) {
                health.hp -= 5;
                std.debug.print("    Entity {any} took poison damage (HP: {})\n", .{ entity, health.hp });
                break;
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("=== Sparze ECS: Tags and TagQuery ===\n\n", .{});

    // ==========================================================================
    // Create Entities with Tags
    // ==========================================================================
    std.debug.print("--- Creating entities ---\n", .{});

    // Player entity
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Health, .{ .hp = 100 });
    try world.addTag(player, Player);
    try world.addTag(player, Active);
    std.debug.print("  Player: Position, Health, [Player], [Active]\n", .{});

    // Regular enemy
    const enemy1 = world.createEntity();
    try world.addComponent(enemy1, Position, .{ .x = 50.0, .y = 0.0 });
    try world.addComponent(enemy1, Health, .{ .hp = 30 });
    try world.addTag(enemy1, Enemy);
    try world.addTag(enemy1, Active);
    std.debug.print("  Enemy1: Position, Health, [Enemy], [Active]\n", .{});

    // Poisoned enemy
    const enemy2 = world.createEntity();
    try world.addComponent(enemy2, Position, .{ .x = 75.0, .y = 0.0 });
    try world.addComponent(enemy2, Health, .{ .hp = 25 });
    try world.addTag(enemy2, Enemy);
    try world.addTag(enemy2, Active);
    try world.addTag(enemy2, Poisoned);
    std.debug.print("  Enemy2: Position, Health, [Enemy], [Active], [Poisoned]\n", .{});

    // Boss enemy
    const boss = world.createEntity();
    try world.addComponent(boss, Position, .{ .x = 100.0, .y = 0.0 });
    try world.addComponent(boss, Health, .{ .hp = 200 });
    try world.addTag(boss, Enemy);
    try world.addTag(boss, Boss);
    try world.addTag(boss, Active);
    std.debug.print("  Boss: Position, Health, [Enemy], [Boss], [Active]\n", .{});

    // Inactive enemy (spawned but not active yet)
    const inactive = world.createEntity();
    try world.addComponent(inactive, Health, .{ .hp = 40 });
    try world.addTag(inactive, Enemy);
    // Note: No Active tag
    std.debug.print("  Inactive: Health, [Enemy] (no Active tag)\n", .{});

    std.debug.print("\n", .{});

    // ==========================================================================
    // Run Systems
    // ==========================================================================
    std.debug.print("--- Running systems ---\n", .{});

    try world.runSystem(playerInputSystem);
    std.debug.print("\n", .{});

    try world.runSystem(enemyAISystem);
    std.debug.print("\n", .{});

    try world.runSystem(bossSystem);
    std.debug.print("\n", .{});

    try world.runSystem(enemyRenderSystem);
    std.debug.print("\n", .{});

    try world.runSystem(healthyEnemySystem);
    std.debug.print("\n", .{});

    try world.runSystem(poisonSystem);
    std.debug.print("\n", .{});

    // ==========================================================================
    // Dynamic Tag Manipulation
    // ==========================================================================
    std.debug.print("--- Dynamic tag manipulation ---\n", .{});

    // Poison the boss
    std.debug.print("  Poisoning the boss...\n", .{});
    try world.addTag(boss, Poisoned);

    // Check tag presence
    std.debug.print("  Boss has Poisoned tag: {}\n", .{world.hasComponent(boss, Poisoned)});

    // Remove poison from enemy2
    std.debug.print("  Curing enemy2...\n", .{});
    world.removeTag(enemy2, Poisoned);
    std.debug.print("  Enemy2 has Poisoned tag: {}\n", .{world.hasComponent(enemy2, Poisoned)});

    // Run poison system again
    std.debug.print("\n", .{});
    try world.runSystem(poisonSystem);

    // ==========================================================================
    // Tag Counts
    // ==========================================================================
    std.debug.print("\n--- Tag counts ---\n", .{});

    const player_count = sparze.SingleTag(Player).init(world.getTagStoragePtr(Player)).entities.len;
    const enemy_count = sparze.SingleTag(Enemy).init(world.getTagStoragePtr(Enemy)).entities.len;
    const boss_count = sparze.SingleTag(Boss).init(world.getTagStoragePtr(Boss)).entities.len;
    const active_count = sparze.SingleTag(Active).init(world.getTagStoragePtr(Active)).entities.len;
    const poisoned_count = sparze.SingleTag(Poisoned).init(world.getTagStoragePtr(Poisoned)).entities.len;

    std.debug.print("  Players: {}\n", .{player_count});
    std.debug.print("  Enemies: {}\n", .{enemy_count});
    std.debug.print("  Bosses: {}\n", .{boss_count});
    std.debug.print("  Active: {}\n", .{active_count});
    std.debug.print("  Poisoned: {}\n", .{poisoned_count});

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("\n=== Key Takeaways ===\n", .{});
    std.debug.print("1. Tags are empty structs - zero memory per entity\n", .{});
    std.debug.print("2. Use addTag/removeTag instead of addComponent for tags\n", .{});
    std.debug.print("3. SingleTag(T) iterates ALL entities with tag T\n", .{});
    std.debug.print("4. TagQuery combines multiple tags with Optional/Exclude\n", .{});
    std.debug.print("5. Tags are perfect for: Player/Enemy, Active/Inactive, Status effects\n", .{});
    std.debug.print("6. Prefer tags over bool components - more efficient storage\n", .{});
}
