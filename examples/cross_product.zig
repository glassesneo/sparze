const std = @import("std");
const sparze = @import("sparze");

// Define component types
const Projectile = struct {};
const Enemy = struct {};
const Transform = struct {
    x: f32,
    y: f32,
};
const Collider = struct {
    radius: f32,
};
const Health = struct {
    hp: i32,
};
const Dead = struct {};

// Event for collision detection
const CollisionEvent = struct {
    projectile: sparze.Entity,
    enemy: sparze.Entity,
};

const World = sparze.World(
    struct { Projectile, Enemy, Transform, Collider, Health, Dead },
    struct {},
    struct { CollisionEvent },
);

/// System that detects collisions between projectiles and enemies
/// using the CrossProductIterator API
fn collisionDetectionSystem(
    mut_projectile_query: sparze.Query(struct { Projectile, Transform, Collider, sparze.Exclude(Dead) }),
    mut_enemy_query: sparze.Query(struct { Enemy, Transform, Collider, sparze.Exclude(Dead) }),
    collision_writer: sparze.EventWriter(CollisionEvent),
) !void {
    var projectile_query = mut_projectile_query;
    var enemy_query = mut_enemy_query;

    // Use cross product iterator to check all projectiles against all enemies
    var cross = projectile_query.crossProduct(&enemy_query);

    var collision_count: usize = 0;
    while (cross.next()) |pair| {
        const proj_entity, const enemy_entity = pair;

        // Get transforms and colliders for collision check
        const proj_transform = projectile_query.getComponent(proj_entity, Transform);
        const proj_collider = projectile_query.getComponent(proj_entity, Collider);

        const enemy_transform = enemy_query.getComponent(enemy_entity, Transform);
        const enemy_collider = enemy_query.getComponent(enemy_entity, Collider);

        // Calculate distance between entities
        const dx = proj_transform.x - enemy_transform.x;
        const dy = proj_transform.y - enemy_transform.y;
        const dist_sq = dx * dx + dy * dy;
        const radius_sum = proj_collider.radius + enemy_collider.radius;

        // Check if collision occurred
        if (dist_sq < radius_sum * radius_sum) {
            try collision_writer.enqueue(.{
                .projectile = proj_entity,
                .enemy = enemy_entity,
            });
            collision_count += 1;
        }
    }

    std.debug.print("Detected {d} collisions\n", .{collision_count});
}

/// System that handles collision events by applying damage
fn collisionResponseSystem(
    collision_reader: sparze.EventReader(CollisionEvent),
    health_query: sparze.SingleQuery(Health),
    commands: anytype,
) !void {
    for (collision_reader.queue) |collision| {
        std.debug.print("Processing collision: projectile={d} enemy={d}\n", .{
            collision.projectile,
            collision.enemy,
        });

        // Destroy projectile
        try commands.destroyEntity(collision.projectile);

        // Apply damage to enemy
        for (health_query.entities, health_query.components) |entity, *health| {
            if (entity == collision.enemy) {
                health.hp -= 25;
                std.debug.print("  Enemy {d} took damage, HP: {d}\n", .{ entity, health.hp });

                // Mark as dead if HP <= 0
                if (health.hp <= 0) {
                    try commands.addTag(entity, Dead);
                    std.debug.print("  Enemy {d} died\n", .{entity});
                }
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

    std.debug.print("=== CrossProductIterator Example: Projectile vs Enemy Collision Detection ===\n\n", .{});

    // Spawn projectiles
    std.debug.print("Spawning projectiles...\n", .{});
    const proj1 = world.createEntity();
    try world.addTag(proj1, Projectile);
    try world.addComponent(proj1, Transform, .{ .x = 10.0, .y = 10.0 });
    try world.addComponent(proj1, Collider, .{ .radius = 5.0 });
    std.debug.print("  Projectile {d} at (10.0, 10.0)\n", .{proj1});

    const proj2 = world.createEntity();
    try world.addTag(proj2, Projectile);
    try world.addComponent(proj2, Transform, .{ .x = 50.0, .y = 50.0 });
    try world.addComponent(proj2, Collider, .{ .radius = 5.0 });
    std.debug.print("  Projectile {d} at (50.0, 50.0)\n", .{proj2});

    const proj3 = world.createEntity();
    try world.addTag(proj3, Projectile);
    try world.addComponent(proj3, Transform, .{ .x = 100.0, .y = 100.0 });
    try world.addComponent(proj3, Collider, .{ .radius = 5.0 });
    std.debug.print("  Projectile {d} at (100.0, 100.0)\n", .{proj3});

    // Spawn enemies
    std.debug.print("\nSpawning enemies...\n", .{});
    const enemy1 = world.createEntity();
    try world.addTag(enemy1, Enemy);
    try world.addComponent(enemy1, Transform, .{ .x = 15.0, .y = 15.0 }); // Close to proj1
    try world.addComponent(enemy1, Collider, .{ .radius = 10.0 });
    try world.addComponent(enemy1, Health, .{ .hp = 100 });
    std.debug.print("  Enemy {d} at (15.0, 15.0) with HP=100\n", .{enemy1});

    const enemy2 = world.createEntity();
    try world.addTag(enemy2, Enemy);
    try world.addComponent(enemy2, Transform, .{ .x = 55.0, .y = 55.0 }); // Close to proj2
    try world.addComponent(enemy2, Collider, .{ .radius = 10.0 });
    try world.addComponent(enemy2, Health, .{ .hp = 50 });
    std.debug.print("  Enemy {d} at (55.0, 55.0) with HP=50\n", .{enemy2});

    const enemy3 = world.createEntity();
    try world.addTag(enemy3, Enemy);
    try world.addComponent(enemy3, Transform, .{ .x = 200.0, .y = 200.0 }); // Far from all projectiles
    try world.addComponent(enemy3, Collider, .{ .radius = 10.0 });
    try world.addComponent(enemy3, Health, .{ .hp = 75 });
    std.debug.print("  Enemy {d} at (200.0, 200.0) with HP=75\n", .{enemy3});

    // Run collision detection for multiple frames
    std.debug.print("\n=== Frame 1: Initial collision detection ===\n", .{});
    world.beginFrame();
    try world.runSystem(collisionDetectionSystem);
    try world.endFrame();

    std.debug.print("\n=== Frame 2: Process collision events ===\n", .{});
    world.beginFrame();
    try world.runSystem(collisionResponseSystem);
    try world.endFrame();

    // Check remaining entities
    std.debug.print("\n=== Final state ===\n", .{});

    const projectile_query = sparze.SingleTag(Projectile).init(world.getTagStoragePtr(Projectile));
    const enemy_query = sparze.SingleTag(Enemy).init(world.getTagStoragePtr(Enemy));
    const dead_query = sparze.SingleTag(Dead).init(world.getTagStoragePtr(Dead));

    std.debug.print("Remaining projectiles: {d}\n", .{projectile_query.entities.len});
    std.debug.print("Remaining enemies: {d}\n", .{enemy_query.entities.len});
    std.debug.print("Dead enemies: {d}\n", .{dead_query.entities.len});

    // Print enemy health
    const health_query = sparze.SingleQuery(Health).init(world.getSparseSetPtr(Health));
    for (health_query.entities, health_query.components) |entity, health| {
        std.debug.print("  Enemy {d}: HP={d}\n", .{ entity, health.hp });
    }

    std.debug.print("\n=== Performance comparison note ===\n", .{});
    std.debug.print("CrossProductIterator provides O(N×M) iteration where:\n", .{});
    std.debug.print("  N = number of entities in first query (projectiles)\n", .{});
    std.debug.print("  M = number of entities in second query (enemies)\n", .{});
    std.debug.print("\nBenefits:\n", .{});
    std.debug.print("  - Clean API without manual double loops\n", .{});
    std.debug.print("  - Automatic filter application from both queries\n", .{});
    std.debug.print("  - Type-safe and composable\n", .{});
    std.debug.print("  - Works with any query filter types (Query, SingleQuery, SingleTag, etc.)\n", .{});
}
