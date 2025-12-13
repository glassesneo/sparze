// pairs_and_cross_products.zig - Specialized Iteration Patterns
//
// This example demonstrates advanced iteration patterns for entity pairs:
// - combinations() for unique pairs (i < j) within a single query
// - crossProduct() for N×M pairs between two different queries
// - Use cases: collision detection, interaction systems, AI targeting
//
// Run with: zig build run-pairs_and_cross_products

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Component Definitions
// =============================================================================
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Collider = struct { radius: f32 };

// Tag components for different entity types
const Player = struct {};
const Enemy = struct {};
const Projectile = struct {};
const Pickup = struct {};

const World = sparze.World(
    struct { Position, Velocity, Collider, Player, Enemy, Projectile, Pickup },
    struct {},
    struct {},
);

// =============================================================================
// Helper Functions
// =============================================================================

fn distance(p1: Position, p2: Position) f32 {
    const dx = p2.x - p1.x;
    const dy = p2.y - p1.y;
    return @sqrt(dx * dx + dy * dy);
}

fn circlesOverlap(p1: Position, r1: f32, p2: Position, r2: f32) bool {
    return distance(p1, p2) < r1 + r2;
}

// =============================================================================
// Systems Using combinations() - Same-Type Collision
// =============================================================================

/// Enemy-Enemy collision using combinations()
/// combinations() yields unique pairs (i < j), so we never check (A,B) and (B,A)
fn enemyEnemyCollision(
    query: sparze.Query(struct { Position, Collider, Enemy }),
) !void {
    std.debug.print("  [enemyEnemyCollision] Checking enemy-enemy collisions\n", .{});

    // combinations() returns all unique pairs from the SAME query
    var pairs = query.combinations();
    var collision_count: u32 = 0;

    while (pairs.next()) |pair| {
        const entity_a, const entity_b = pair;

        const pos_a = query.getComponent(entity_a, Position);
        const col_a = query.getComponent(entity_a, Collider);
        const pos_b = query.getComponent(entity_b, Position);
        const col_b = query.getComponent(entity_b, Collider);

        if (circlesOverlap(pos_a, col_a.radius, pos_b, col_b.radius)) {
            collision_count += 1;
            std.debug.print("    Collision: Enemy {any} <-> Enemy {any}\n", .{ entity_a, entity_b });
        }
    }

    std.debug.print("    Total enemy-enemy collisions: {}\n", .{collision_count});
}

/// Projectile-Projectile collision (e.g., for bullet cancellation)
fn projectileProjectileCollision(
    query: sparze.Query(struct { Position, Collider, Projectile }),
) !void {
    std.debug.print("  [projectileProjectileCollision] Checking projectile-projectile\n", .{});

    var pairs = query.combinations();
    var collision_count: u32 = 0;

    while (pairs.next()) |pair| {
        const entity_a, const entity_b = pair;

        const pos_a = query.getComponent(entity_a, Position);
        const col_a = query.getComponent(entity_a, Collider);
        const pos_b = query.getComponent(entity_b, Position);
        const col_b = query.getComponent(entity_b, Collider);

        if (circlesOverlap(pos_a, col_a.radius, pos_b, col_b.radius)) {
            collision_count += 1;
            std.debug.print("    Collision: Projectile {any} <-> Projectile {any}\n", .{ entity_a, entity_b });
        }
    }

    std.debug.print("    Total projectile-projectile collisions: {}\n", .{collision_count});
}

// =============================================================================
// Systems Using crossProduct() - Different-Type Collision
// =============================================================================

/// Player-Enemy collision using crossProduct()
/// crossProduct() yields all N×M pairs between TWO different queries
fn playerEnemyCollision(
    player_query: sparze.Query(struct { Position, Collider, Player }),
    enemy_query: sparze.Query(struct { Position, Collider, Enemy }),
) !void {
    std.debug.print("  [playerEnemyCollision] Checking player-enemy collisions\n", .{});

    // crossProduct() returns all pairs from query1 × query2
    var cross = player_query.crossProduct(&enemy_query);
    var collision_count: u32 = 0;

    while (cross.next()) |pair| {
        const player_entity, const enemy_entity = pair;

        const player_pos = player_query.getComponent(player_entity, Position);
        const player_col = player_query.getComponent(player_entity, Collider);
        const enemy_pos = enemy_query.getComponent(enemy_entity, Position);
        const enemy_col = enemy_query.getComponent(enemy_entity, Collider);

        if (circlesOverlap(player_pos, player_col.radius, enemy_pos, enemy_col.radius)) {
            collision_count += 1;
            std.debug.print("    Collision: Player {any} <-> Enemy {any}\n", .{ player_entity, enemy_entity });
        }
    }

    std.debug.print("    Total player-enemy collisions: {}\n", .{collision_count});
}

/// Projectile-Enemy collision (damage dealing)
fn projectileEnemyCollision(
    projectile_query: sparze.Query(struct { Position, Collider, Projectile }),
    enemy_query: sparze.Query(struct { Position, Collider, Enemy }),
) !void {
    std.debug.print("  [projectileEnemyCollision] Checking projectile-enemy collisions\n", .{});

    var cross = projectile_query.crossProduct(&enemy_query);
    var collision_count: u32 = 0;

    while (cross.next()) |pair| {
        const proj_entity, const enemy_entity = pair;

        const proj_pos = projectile_query.getComponent(proj_entity, Position);
        const proj_col = projectile_query.getComponent(proj_entity, Collider);
        const enemy_pos = enemy_query.getComponent(enemy_entity, Position);
        const enemy_col = enemy_query.getComponent(enemy_entity, Collider);

        if (circlesOverlap(proj_pos, proj_col.radius, enemy_pos, enemy_col.radius)) {
            collision_count += 1;
            std.debug.print("    HIT: Projectile {any} -> Enemy {any}\n", .{ proj_entity, enemy_entity });
        }
    }

    std.debug.print("    Total projectile-enemy hits: {}\n", .{collision_count});
}

/// Player-Pickup collision (item collection)
fn playerPickupCollision(
    player_query: sparze.Query(struct { Position, Collider, Player }),
    pickup_query: sparze.Query(struct { Position, Collider, Pickup }),
) !void {
    std.debug.print("  [playerPickupCollision] Checking player-pickup collisions\n", .{});

    var cross = player_query.crossProduct(&pickup_query);
    var collected: u32 = 0;

    while (cross.next()) |pair| {
        const player_entity, const pickup_entity = pair;

        const player_pos = player_query.getComponent(player_entity, Position);
        const player_col = player_query.getComponent(player_entity, Collider);
        const pickup_pos = pickup_query.getComponent(pickup_entity, Position);
        const pickup_col = pickup_query.getComponent(pickup_entity, Collider);

        if (circlesOverlap(player_pos, player_col.radius, pickup_pos, pickup_col.radius)) {
            collected += 1;
            std.debug.print("    COLLECTED: Player {any} <- Pickup {any}\n", .{ player_entity, pickup_entity });
        }
    }

    std.debug.print("    Total pickups collected: {}\n", .{collected});
}

// =============================================================================
// Using SingleTag with crossProduct()
// =============================================================================

/// AI targeting using SingleTag crossProduct
fn aiTargeting(
    enemies: sparze.SingleTag(Enemy),
    players: sparze.SingleTag(Player),
    positions: sparze.SingleQuery(Position),
) !void {
    std.debug.print("  [aiTargeting] Enemies targeting players\n", .{});

    // SingleTag also supports crossProduct
    var cross = enemies.crossProduct(&players);

    while (cross.next()) |pair| {
        const enemy_entity, const player_entity = pair;

        // Get positions from separate storage
        var enemy_pos: ?Position = null;
        var player_pos: ?Position = null;

        for (positions.entities, positions.components) |e, pos| {
            if (e == enemy_entity) enemy_pos = pos;
            if (e == player_entity) player_pos = pos;
        }

        if (enemy_pos != null and player_pos != null) {
            const dist = distance(enemy_pos.?, player_pos.?);
            std.debug.print("    Enemy {any} -> Player {any}: distance={d:.1}\n", .{
                enemy_entity,
                player_entity,
                dist,
            });
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Sparze ECS: Pairs and Cross Products ===\n\n", .{});

    var world = World.init(allocator);
    defer world.deinit();

    // ==========================================================================
    // Create Test Entities
    // ==========================================================================
    std.debug.print("--- Creating entities ---\n", .{});

    // Player at origin
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Collider, .{ .radius = 15.0 });
    try world.addTag(player, Player);
    std.debug.print("  Player at (0, 0) radius=15\n", .{});

    // Three enemies - two close together, one far
    const enemy1 = world.createEntity();
    try world.addComponent(enemy1, Position, .{ .x = 20.0, .y = 0.0 });
    try world.addComponent(enemy1, Collider, .{ .radius = 10.0 });
    try world.addTag(enemy1, Enemy);
    std.debug.print("  Enemy1 at (20, 0) radius=10\n", .{});

    const enemy2 = world.createEntity();
    try world.addComponent(enemy2, Position, .{ .x = 25.0, .y = 5.0 });
    try world.addComponent(enemy2, Collider, .{ .radius = 10.0 });
    try world.addTag(enemy2, Enemy);
    std.debug.print("  Enemy2 at (25, 5) radius=10\n", .{});

    const enemy3 = world.createEntity();
    try world.addComponent(enemy3, Position, .{ .x = 100.0, .y = 100.0 });
    try world.addComponent(enemy3, Collider, .{ .radius = 10.0 });
    try world.addTag(enemy3, Enemy);
    std.debug.print("  Enemy3 at (100, 100) radius=10 (far)\n", .{});

    // Two projectiles
    const proj1 = world.createEntity();
    try world.addComponent(proj1, Position, .{ .x = 18.0, .y = 0.0 });
    try world.addComponent(proj1, Collider, .{ .radius = 3.0 });
    try world.addTag(proj1, Projectile);
    std.debug.print("  Projectile1 at (18, 0) radius=3\n", .{});

    const proj2 = world.createEntity();
    try world.addComponent(proj2, Position, .{ .x = 19.0, .y = 1.0 });
    try world.addComponent(proj2, Collider, .{ .radius = 3.0 });
    try world.addTag(proj2, Projectile);
    std.debug.print("  Projectile2 at (19, 1) radius=3\n", .{});

    // Pickup near player
    const pickup = world.createEntity();
    try world.addComponent(pickup, Position, .{ .x = 10.0, .y = 0.0 });
    try world.addComponent(pickup, Collider, .{ .radius = 5.0 });
    try world.addTag(pickup, Pickup);
    std.debug.print("  Pickup at (10, 0) radius=5\n\n", .{});

    // ==========================================================================
    // Run Collision Systems
    // ==========================================================================
    std.debug.print("--- combinations(): Same-type collisions ---\n", .{});

    try world.runSystem(enemyEnemyCollision);
    std.debug.print("\n", .{});

    try world.runSystem(projectileProjectileCollision);
    std.debug.print("\n", .{});

    std.debug.print("--- crossProduct(): Different-type collisions ---\n", .{});

    try world.runSystem(playerEnemyCollision);
    std.debug.print("\n", .{});

    try world.runSystem(projectileEnemyCollision);
    std.debug.print("\n", .{});

    try world.runSystem(playerPickupCollision);
    std.debug.print("\n", .{});

    std.debug.print("--- SingleTag crossProduct ---\n", .{});
    try world.runSystem(aiTargeting);
    std.debug.print("\n", .{});

    // ==========================================================================
    // Complexity Analysis
    // ==========================================================================
    std.debug.print("=== Complexity Analysis ===\n", .{});
    std.debug.print("\ncombinations() - O(n²/2):\n", .{});
    std.debug.print("  - For n entities, yields n*(n-1)/2 unique pairs\n", .{});
    std.debug.print("  - 3 enemies → 3 pairs: (e1,e2), (e1,e3), (e2,e3)\n", .{});
    std.debug.print("  - Never checks (A,B) AND (B,A) - no duplicates\n", .{});
    std.debug.print("  - Use for: same-type collision, physics constraints\n", .{});

    std.debug.print("\ncrossProduct() - O(n*m):\n", .{});
    std.debug.print("  - For n × m entities, yields n*m pairs\n", .{});
    std.debug.print("  - 2 projectiles × 3 enemies → 6 pairs\n", .{});
    std.debug.print("  - Each entity from query1 paired with ALL from query2\n", .{});
    std.debug.print("  - Use for: damage dealing, AI targeting, asymmetric interactions\n", .{});

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("\n=== Key Takeaways ===\n", .{});
    std.debug.print("1. combinations() yields unique pairs (i < j) from ONE query\n", .{});
    std.debug.print("2. crossProduct() yields N×M pairs from TWO queries\n", .{});
    std.debug.print("3. Use combinations() for same-type collisions (enemy-enemy)\n", .{});
    std.debug.print("4. Use crossProduct() for different-type interactions (projectile-enemy)\n", .{});
    std.debug.print("5. Both work with Query, TagQuery, SingleQuery, and SingleTag\n", .{});
    std.debug.print("6. Filters are applied automatically during iteration\n", .{});
}
