const std = @import("std");
const sparze = @import("sparze");

// Define components
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };

// Define tags/markers
const Enemy = struct {};
const Dead = struct {};
const Frozen = struct {};
const Static = struct {};
const Boss = struct {};

const World = sparze.World(struct { Position, Velocity, Health, Enemy, Dead, Frozen, Static, Boss }, struct {}, struct {});
const Query = sparze.Query;
const TagQuery = sparze.TagQuery;
const Exclude = sparze.Exclude;

// System 1: Move all entities that have position and velocity, but exclude static objects
fn movementSystem(query: Query(struct { Position, Velocity, Exclude(Static) })) void {
    std.debug.print("\n=== Movement System (Exclude Static) ===\n", .{});
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponentMut(entity, Position);
            const vel = query.getComponent(entity, Velocity);
            pos.x += vel.dx;
            pos.y += vel.dy;
            std.debug.print("  Entity {} moved to ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
            count += 1;
        }
    }
    std.debug.print("  Moved {} entities (static objects excluded)\n", .{count});
}

// System 2: Process living enemies (exclude dead ones)
fn livingEnemySystem(query: Query(struct { Position, Enemy, Exclude(Dead) })) void {
    std.debug.print("\n=== Living Enemy System (Exclude Dead) ===\n", .{});
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const pos = query.getComponent(entity, Position);
            std.debug.print("  Living enemy {} at ({d:.1}, {d:.1})\n", .{ entity, pos.x, pos.y });
            count += 1;
        }
    }
    std.debug.print("  Found {} living enemies\n", .{count});
}

// System 3: Process active enemies (exclude frozen and dead)
fn activeEnemySystem(query: TagQuery(struct { Enemy, Exclude(Frozen), Exclude(Dead) })) void {
    std.debug.print("\n=== Active Enemy System (Exclude Frozen & Dead) ===\n", .{});
    var count: usize = 0;
    for (query.entities) |entity| {
        if (query.filter(entity)) {
            std.debug.print("  Active enemy: {}\n", .{entity});
            count += 1;
        }
    }
    std.debug.print("  Found {} active enemies\n", .{count});
}

// System 4: Damage damageable entities (exclude dead and bosses)
fn damageSystem(query: Query(struct { Health, Exclude(Dead), Exclude(Boss) })) void {
    std.debug.print("\n=== Damage System (Exclude Dead) ===\n", .{});
    const base_damage: i32 = 10;

    for (query.entities) |entity| {
        if (query.filter(entity)) {
            const health = query.getComponentMut(entity, Health);
            health.hp -= base_damage;
            std.debug.print("  Entity {} took {} damage, HP: {}\n", .{ entity, base_damage, health.hp });
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Exclude Modifier Example                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\nDemonstrates Exclude(Component) to filter out entities\n", .{});
    std.debug.print("with specific components or tags.\n", .{});

    // Create entities
    std.debug.print("\n--- Creating Entities ---\n", .{});

    // Regular movable enemy
    const enemy1 = world.createEntity();
    try world.addComponent(enemy1, Position, .{ .x = 10.0, .y = 20.0 });
    try world.addComponent(enemy1, Velocity, .{ .dx = 1.0, .dy = 0.5 });
    try world.addComponent(enemy1, Health, .{ .hp = 100 });
    try world.addTag(enemy1, Enemy);
    std.debug.print("Enemy 1: Movable, living, active\n", .{});

    // Dead enemy (should be excluded from living/active systems)
    const enemy2 = world.createEntity();
    try world.addComponent(enemy2, Position, .{ .x = 30.0, .y = 40.0 });
    try world.addComponent(enemy2, Velocity, .{ .dx = -1.0, .dy = -0.5 });
    try world.addComponent(enemy2, Health, .{ .hp = 0 });
    try world.addTag(enemy2, Enemy);
    try world.addTag(enemy2, Dead);
    std.debug.print("Enemy 2: Dead (excluded from most systems)\n", .{});

    // Frozen enemy (should be excluded from active systems)
    const enemy3 = world.createEntity();
    try world.addComponent(enemy3, Position, .{ .x = 50.0, .y = 60.0 });
    try world.addComponent(enemy3, Velocity, .{ .dx = 0.5, .dy = 1.0 });
    try world.addComponent(enemy3, Health, .{ .hp = 80 });
    try world.addTag(enemy3, Enemy);
    try world.addTag(enemy3, Frozen);
    std.debug.print("Enemy 3: Frozen (excluded from active systems)\n", .{});

    // Boss enemy
    const boss = world.createEntity();
    try world.addComponent(boss, Position, .{ .x = 100.0, .y = 100.0 });
    try world.addComponent(boss, Velocity, .{ .dx = 0.2, .dy = 0.2 });
    try world.addComponent(boss, Health, .{ .hp = 500 });
    try world.addTag(boss, Enemy);
    try world.addTag(boss, Boss);
    std.debug.print("Boss: Movable, living, active, high HP\n", .{});

    // Static obstacle
    const obstacle = world.createEntity();
    try world.addComponent(obstacle, Position, .{ .x = 200.0, .y = 200.0 });
    try world.addComponent(obstacle, Velocity, .{ .dx = 0.0, .dy = 0.0 });
    try world.addTag(obstacle, Static);
    std.debug.print("Obstacle: Static (excluded from movement)\n", .{});

    // Run game loop
    for (0..3) |frame| {
        std.debug.print("\n\n╔═══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║                    Frame {}                               ║\n", .{frame + 1});
        std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});

        try world.runSystem(movementSystem);
        try world.runSystem(livingEnemySystem);
        try world.runSystem(activeEnemySystem);

        if (frame == 1) {
            try world.runSystem(damageSystem);
        }
    }

    std.debug.print("\n\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                      Summary                              ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\nExclude modifier allows filtering out entities:\n", .{});
    std.debug.print("• Exclude(Dead) - Skip dead entities\n", .{});
    std.debug.print("• Exclude(Frozen) - Skip frozen entities\n", .{});
    std.debug.print("• Exclude(Static) - Skip static objects\n", .{});
    std.debug.print("\nMultiple excludes can be combined:\n", .{});
    std.debug.print("• Query(struct {{ Enemy, Exclude(Dead), Exclude(Frozen) }}) - Active enemies\n", .{});
    std.debug.print("• Query(struct {{ Health, Exclude(Dead), Exclude(Boss) }}) - Damageable non-boss entities\n", .{});
}
