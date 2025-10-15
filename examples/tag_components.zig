const std = @import("std");
const sparze = @import("sparze");

// Define regular components
const Position = struct {
    x: f32,
    y: f32,
};

const Health = struct {
    hp: i32,
};

// Define tag components (zero-sized marker components)
const Player = struct {};
const Enemy = struct {};
const Active = struct {};
const Boss = struct {};

const World = sparze.World(struct { Position, Health, Player, Enemy, Active, Boss });
const SingleQuery = sparze.SingleQuery;
const Query = sparze.Query;

// System that processes only player entities
fn playerSystem(query: SingleQuery(Player)) !void {
    std.debug.print("Player entities: {}\n", .{query.entities.len});
    for (query.entities) |entity| {
        std.debug.print("  Player entity: {}\n", .{entity});
    }
}

// System that processes only enemy entities
fn enemySystem(query: SingleQuery(Enemy)) !void {
    std.debug.print("Enemy entities: {}\n", .{query.entities.len});
    for (query.entities) |entity| {
        std.debug.print("  Enemy entity: {}\n", .{entity});
    }
}

// System that combines tags with regular components
fn activePlayerHealthSystem(query: Query(struct { Player, Active, Health })) !void {
    std.debug.print("Active players with health:\n", .{});
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.hasAllComponents(entity)) {
            if (query.getComponent(entity, Health)) |health| {
                std.debug.print("  Entity {}: {} HP\n", .{ entity, health.hp });
                count += 1;
            }
        }
    }
    std.debug.print("  Total: {} active players\n", .{count});
}

// System that processes enemies with position (mixing tags and components)
fn enemyPositionSystem(query: Query(struct { Enemy, Position })) !void {
    std.debug.print("Enemies with position:\n", .{});
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.hasAllComponents(entity)) {
            if (query.getComponent(entity, Position)) |pos| {
                std.debug.print("  Enemy {} at ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
                count += 1;
            }
        }
    }
    std.debug.print("  Total: {} enemies\n", .{count});
}

// System demonstrating boss enemies (entities with multiple tags)
fn bossSystem(query: Query(struct { Enemy, Boss })) !void {
    std.debug.print("Boss enemies:\n", .{});
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.hasAllComponents(entity)) {
            std.debug.print("  Boss entity: {}\n", .{entity});
            count += 1;
        }
    }
    std.debug.print("  Total: {} bosses\n", .{count});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("=== Tag Components Example ===\n\n", .{});

    // Create player entities
    std.debug.print("Creating entities...\n", .{});
    const player1 = world.createEntity();
    try world.addTag(player1, Player);
    try world.addTag(player1, Active);
    try world.addComponent(player1, Health, .{ .hp = 100 });
    try world.addComponent(player1, Position, .{ .x = 10.0, .y = 20.0 });
    std.debug.print("  Player 1: active with health and position\n", .{});

    const player2 = world.createEntity();
    try world.addTag(player2, Player);
    try world.addComponent(player2, Health, .{ .hp = 75 });
    std.debug.print("  Player 2: inactive with health (no Active tag)\n", .{});

    // Create enemy entities
    const enemy1 = world.createEntity();
    try world.addTag(enemy1, Enemy);
    try world.addComponent(enemy1, Position, .{ .x = 50.0, .y = 30.0 });
    std.debug.print("  Enemy 1: regular enemy with position\n", .{});

    const enemy2 = world.createEntity();
    try world.addTag(enemy2, Enemy);
    try world.addComponent(enemy2, Position, .{ .x = 100.0, .y = 80.0 });
    std.debug.print("  Enemy 2: regular enemy with position\n", .{});

    // Create boss enemy (multiple tags)
    const boss = world.createEntity();
    try world.addTag(boss, Enemy);
    try world.addTag(boss, Boss);
    try world.addComponent(boss, Health, .{ .hp = 500 });
    try world.addComponent(boss, Position, .{ .x = 200.0, .y = 150.0 });
    std.debug.print("  Boss: enemy with Boss tag, health, and position\n", .{});

    // Run systems to demonstrate tag-based queries
    std.debug.print("\n=== Running Systems ===\n\n", .{});

    try world.runSystem(playerSystem);
    std.debug.print("\n", .{});

    try world.runSystem(enemySystem);
    std.debug.print("\n", .{});

    try world.runSystem(activePlayerHealthSystem);
    std.debug.print("\n", .{});

    try world.runSystem(enemyPositionSystem);
    std.debug.print("\n", .{});

    try world.runSystem(bossSystem);
    std.debug.print("\n", .{});

    // Demonstrate tag removal
    std.debug.print("=== Removing Active Tag from Player 1 ===\n\n", .{});
    world.removeTag(player1, Active);

    try world.runSystem(activePlayerHealthSystem);
    std.debug.print("\n", .{});

    // Demonstrate tag checking
    std.debug.print("=== Tag Membership Checks ===\n\n", .{});
    std.debug.print("Player 1 has Player tag: {}\n", .{world.hasComponent(player1, Player)});
    std.debug.print("Player 1 has Active tag: {}\n", .{world.hasComponent(player1, Active)});
    std.debug.print("Player 1 has Enemy tag: {}\n", .{world.hasComponent(player1, Enemy)});
    std.debug.print("Boss has Enemy tag: {}\n", .{world.hasComponent(boss, Enemy)});
    std.debug.print("Boss has Boss tag: {}\n", .{world.hasComponent(boss, Boss)});
}
