// events_pipeline.zig - Frame-to-Frame Communication with Events
//
// This example demonstrates the event system in Sparze:
// - Declaring event types in World definition
// - EventWriter for sending events (current frame)
// - EventReader for receiving events (previous frame)
// - Double-buffering: events written in frame N readable in frame N+1
// - Decoupled system communication patterns
//
// Run with: zig build run-events_pipeline

const std = @import("std");
const sparze = @import("sparze");

// =============================================================================
// Component Definitions
// =============================================================================
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: i32 };
const Collider = struct { radius: f32 };

// =============================================================================
// Event Definitions
// =============================================================================
// Events are plain structs. They carry data between systems across frames.

/// Collision between two entities
const CollisionEvent = struct {
    entity_a: sparze.Entity,
    entity_b: sparze.Entity,
    overlap: f32,
};

/// Damage dealt to an entity
const DamageEvent = struct {
    target: sparze.Entity,
    amount: i32,
    source: ?sparze.Entity,
};

/// Entity death notification
const DeathEvent = struct {
    entity: sparze.Entity,
    position: Position,
};

/// Spawn request (for new entities)
const SpawnEvent = struct {
    x: f32,
    y: f32,
    is_enemy: bool,
};

const World = sparze.World(
    struct { Position, Velocity, Health, Collider },
    struct {},
    struct { CollisionEvent, DamageEvent, DeathEvent, SpawnEvent }, // Events!
    .{},
);

// =============================================================================
// Systems Using Events
// =============================================================================

/// Collision detection - writes CollisionEvents
fn collisionSystem(
    query: sparze.Query(struct { Position, Collider }),
    writer: sparze.EventWriter(CollisionEvent),
) !void {
    const entities = query.entities;

    // Simple O(n²) collision detection
    for (entities, 0..) |entity_a, i| {
        if (!query.filter(entity_a)) continue;
        const pos_a = query.getComponent(entity_a, Position);
        const col_a = query.getComponent(entity_a, Collider);

        for (entities[i + 1 ..]) |entity_b| {
            if (!query.filter(entity_b)) continue;
            const pos_b = query.getComponent(entity_b, Position);
            const col_b = query.getComponent(entity_b, Collider);

            // Check circle collision
            const dx = pos_b.x - pos_a.x;
            const dy = pos_b.y - pos_a.y;
            const dist_sq = dx * dx + dy * dy;
            const min_dist = col_a.radius + col_b.radius;

            if (dist_sq < min_dist * min_dist) {
                const dist = @sqrt(dist_sq);
                const overlap = min_dist - dist;

                // Emit collision event
                try writer.enqueue(.{
                    .entity_a = entity_a,
                    .entity_b = entity_b,
                    .overlap = overlap,
                });
                std.debug.print("  [collision] {any} <-> {any} (overlap={d:.1})\n", .{
                    entity_a,
                    entity_b,
                    overlap,
                });
            }
        }
    }
}

/// Collision response - reads CollisionEvents, writes DamageEvents
fn collisionResponseSystem(
    reader: sparze.EventReader(CollisionEvent),
    writer: sparze.EventWriter(DamageEvent),
) !void {
    for (reader.queue) |collision| {
        // Both entities take damage based on overlap
        const damage: i32 = @intFromFloat(collision.overlap * 10.0);

        try writer.enqueue(.{
            .target = collision.entity_a,
            .amount = damage,
            .source = collision.entity_b,
        });
        try writer.enqueue(.{
            .target = collision.entity_b,
            .amount = damage,
            .source = collision.entity_a,
        });

        std.debug.print("  [response] Collision caused {} damage to both entities\n", .{damage});
    }
}

/// Damage application - reads DamageEvents, writes DeathEvents
fn damageSystem(
    reader: sparze.EventReader(DamageEvent),
    death_writer: sparze.EventWriter(DeathEvent),
    health_query: sparze.SingleQuery(Health),
    pos_query: sparze.SingleQuery(Position),
) !void {
    for (reader.queue) |damage| {
        // Find the health component for this entity
        for (health_query.entities, health_query.components) |entity, *health| {
            if (entity == damage.target) {
                const old_hp = health.hp;
                health.hp -= damage.amount;

                std.debug.print("  [damage] Entity {any}: {} -> {} HP\n", .{
                    entity,
                    old_hp,
                    health.hp,
                });

                // Check for death
                if (health.hp <= 0 and old_hp > 0) {
                    // Get position for death event
                    var death_pos = Position{ .x = 0, .y = 0 };
                    for (pos_query.entities, pos_query.components) |pe, pos| {
                        if (pe == entity) {
                            death_pos = pos;
                            break;
                        }
                    }

                    try death_writer.enqueue(.{
                        .entity = entity,
                        .position = death_pos,
                    });
                    std.debug.print("  [damage] Entity {any} DIED!\n", .{entity});
                }
                break;
            }
        }
    }
}

/// Death handling - reads DeathEvents, writes SpawnEvents
fn deathSystem(
    reader: sparze.EventReader(DeathEvent),
    spawn_writer: sparze.EventWriter(SpawnEvent),
    commands: anytype,
) !void {
    for (reader.queue) |death| {
        std.debug.print("  [death] Processing death of {any} at ({d:.1}, {d:.1})\n", .{
            death.entity,
            death.position.x,
            death.position.y,
        });

        // Destroy the dead entity
        try commands.destroyEntity(death.entity);

        // Spawn a pickup at death location
        try spawn_writer.enqueue(.{
            .x = death.position.x,
            .y = death.position.y,
            .is_enemy = false,
        });
        std.debug.print("  [death] Queued pickup spawn at death location\n", .{});
    }
}

/// Spawning - reads SpawnEvents
fn spawnSystem(
    reader: sparze.EventReader(SpawnEvent),
    commands: anytype,
) !void {
    for (reader.queue) |spawn| {
        const entity = commands.createEntity();
        try commands.addComponent(entity, Position, .{ .x = spawn.x, .y = spawn.y });
        try commands.addComponent(entity, Collider, .{ .radius = 5.0 });

        const label = if (spawn.is_enemy) "enemy" else "pickup";
        std.debug.print("  [spawn] Created {s} at ({d:.1}, {d:.1})\n", .{
            label,
            spawn.x,
            spawn.y,
        });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Sparze ECS: Events Pipeline ===\n\n", .{});

    var world = World.init(allocator);
    defer world.deinit();

    // ==========================================================================
    // Create Initial Entities
    // ==========================================================================
    std.debug.print("--- Creating entities ---\n", .{});

    // Two entities that will collide
    const player = world.createEntity();
    try world.addComponent(player, Position, .{ .x = 0.0, .y = 0.0 });
    try world.addComponent(player, Velocity, .{ .dx = 2.0, .dy = 0.0 });
    try world.addComponent(player, Health, .{ .hp = 100 });
    try world.addComponent(player, Collider, .{ .radius = 10.0 });
    std.debug.print("  Player at (0, 0) with HP=100\n", .{});

    const enemy = world.createEntity();
    try world.addComponent(enemy, Position, .{ .x = 15.0, .y = 0.0 });
    try world.addComponent(enemy, Velocity, .{ .dx = -1.0, .dy = 0.0 });
    try world.addComponent(enemy, Health, .{ .hp = 30 });
    try world.addComponent(enemy, Collider, .{ .radius = 10.0 });
    std.debug.print("  Enemy at (15, 0) with HP=30\n\n", .{});

    // ==========================================================================
    // Run Simulation
    // ==========================================================================
    // Key insight: Events written in frame N are readable in frame N+1!

    var frame: u32 = 0;
    while (frame < 5) : (frame += 1) {
        std.debug.print("===== Frame {} =====\n", .{frame});

        // beginFrame() swaps event buffers
        // - Previous frame's write_buffer becomes this frame's read_buffer
        // - Previous frame's read_buffer becomes this frame's write_buffer (cleared)
        world.beginFrame();

        // Move entities
        const pos_query = sparze.SingleQuery(Position).init(world.getSparseSetPtrMut(Position));
        const vel_query = sparze.SingleQuery(Velocity).init(world.getSparseSetPtr(Velocity));
        for (pos_query.entities, pos_query.components) |entity, *pos| {
            for (vel_query.entities, vel_query.components) |ve, vel| {
                if (entity == ve) {
                    pos.x += vel.dx;
                    pos.y += vel.dy;
                }
            }
        }

        // System pipeline:
        // 1. collisionSystem writes CollisionEvents (readable next frame)
        // 2. collisionResponseSystem reads CollisionEvents, writes DamageEvents
        // 3. damageSystem reads DamageEvents, writes DeathEvents
        // 4. deathSystem reads DeathEvents, writes SpawnEvents
        // 5. spawnSystem reads SpawnEvents

        std.debug.print("--- Collision Detection ---\n", .{});
        try world.runSystem(collisionSystem);

        std.debug.print("--- Collision Response (reads previous frame's collisions) ---\n", .{});
        try world.runSystem(collisionResponseSystem);

        std.debug.print("--- Damage Processing (reads previous frame's damage) ---\n", .{});
        try world.runSystem(damageSystem);

        std.debug.print("--- Death Handling (reads previous frame's deaths) ---\n", .{});
        try world.runSystem(deathSystem);

        std.debug.print("--- Spawning (reads previous frame's spawns) ---\n", .{});
        try world.runSystem(spawnSystem);

        try world.endFrame();

        // Report state
        const survivors = sparze.SingleQuery(Health).init(world.getSparseSetPtr(Health));
        std.debug.print("--- End of frame: {} entities with Health ---\n\n", .{survivors.entities.len});
    }

    // ==========================================================================
    // Event Pipeline Explanation
    // ==========================================================================
    std.debug.print("=== Event Pipeline Timing ===\n", .{});
    std.debug.print("\nFrame N:\n", .{});
    std.debug.print("  - collisionSystem detects collision, writes CollisionEvent\n", .{});
    std.debug.print("  - Event goes into WRITE buffer (not readable yet)\n", .{});
    std.debug.print("\nFrame N+1:\n", .{});
    std.debug.print("  - beginFrame() swaps buffers\n", .{});
    std.debug.print("  - CollisionEvent now in READ buffer\n", .{});
    std.debug.print("  - collisionResponseSystem reads it, writes DamageEvent\n", .{});
    std.debug.print("\nFrame N+2:\n", .{});
    std.debug.print("  - DamageEvent now readable\n", .{});
    std.debug.print("  - damageSystem processes it, writes DeathEvent\n", .{});
    std.debug.print("\nThis 1-frame delay enables:\n", .{});
    std.debug.print("  - Deterministic event ordering\n", .{});
    std.debug.print("  - No mid-frame mutation issues\n", .{});
    std.debug.print("  - Decoupled system design\n", .{});

    // ==========================================================================
    // Key Takeaways
    // ==========================================================================
    std.debug.print("\n=== Key Takeaways ===\n", .{});
    std.debug.print("1. Declare events in World: struct {{ CollisionEvent, DamageEvent }}\n", .{});
    std.debug.print("2. EventWriter(E) sends events (current frame)\n", .{});
    std.debug.print("3. EventReader(E) receives events (previous frame)\n", .{});
    std.debug.print("4. 1-frame delay is intentional - enables determinism\n", .{});
    std.debug.print("5. Multiple systems can read same events\n", .{});
    std.debug.print("6. Use events for decoupled system communication\n", .{});
}
